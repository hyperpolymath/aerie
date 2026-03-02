"""Execute validated & constructed query on device.

This module is responsible for orchestrating the lifecycle of a query execution:
1. Mapping the device driver (SSH/Netmiko or HTTP).
2. Setting up execution timeouts.
3. Managing SSH proxies (jump hosts).
4. Collecting and parsing device output.
"""

# Standard Library
import signal
from typing import TYPE_CHECKING, Any, Dict, Union, Callable

# Project
from hyperglass.log import log
from hyperglass.state import use_state
from hyperglass.util.typing import is_series
from hyperglass.exceptions.public import DeviceTimeout, ResponseEmpty

if TYPE_CHECKING:
    from hyperglass.models.api import Query
    from .drivers import Connection
    from hyperglass.models.data import OutputDataModel

# Local
from .drivers import HttpClient, NetmikoConnection


def map_driver(driver_name: str) -> "Connection":
    """Map a driver string (from configuration) to the corresponding driver class."""

    if driver_name == "hyperglass_http_client":
        return HttpClient

    return NetmikoConnection


def handle_timeout(**exc_args: Any) -> Callable:
    """Return a signal handler function that raises a DeviceTimeout.
    Used with signal.SIGALRM to enforce execution deadlines.
    """

    def handler(*args: Any, **kwargs: Any) -> None:
        raise DeviceTimeout(**exc_args)

    return handler


async def execute(query: "Query") -> Union["OutputDataModel", str]:
    """Initiate query validation and execution against a remote device.

    Flow:
    1. Initialize driver based on device configuration.
    2. Set a POSIX alarm for the request timeout.
    3. Setup SSH proxy tunnel if required.
    4. Collect raw output from the device (via SSH or HTTP).
    5. Pass raw output through the driver's response parser (OutputPluginManager).
    6. Verify the response is not empty and return.
    """
    params = use_state("params")
    output = params.messages.general
    _log = log.bind(query=query.summary(), device=query.device.id)
    _log.debug("Initiating execution")

    # Resolve driver
    mapped_driver = map_driver(query.device.driver)
    driver: "Connection" = mapped_driver(query.device, query)

    # DEADLINE ENFORCEMENT: Set SIGALRM
    signal.signal(
        signal.SIGALRM,
        handle_timeout(error=TimeoutError("Connection timed out"), device=query.device),
    )
    signal.alarm(params.request_timeout - 1)

    # EXECUTION: Collect output
    if query.device.proxy:
        # Jump Host pattern: Open tunnel, then connect through it.
        proxy = driver.setup_proxy()
        with proxy() as tunnel:
            response = await driver.collect(tunnel.local_bind_host, tunnel.local_bind_port)
    else:
        # Direct connection.
        response = await driver.collect()

    # PARSING: Process raw output through plugins
    output = await driver.response(response)

    # VALIDATION: Ensure output content exists
    if is_series(output):
        if len(output) == 0:
            raise ResponseEmpty(query=query)
        output = "\n\n".join(output)

    elif isinstance(output, str):
        # If the output is a string (not structured) and is empty,
        # produce an error.
        if output == "" or output == "\n":
            raise ResponseEmpty(query=query)

    elif isinstance(output, Dict):
        # If the output an empty dict, responses have data, produce an
        # error.
        if not output:
            raise ResponseEmpty(query=query)

    # RESET: Disable the alarm
    signal.alarm(0)

    return output
