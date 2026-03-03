"""API Routes for the hyperglass Network Looking Glass.

This module implements the Litestar-based REST API, providing endpoints 
for device discovery, query execution, and system information.
"""

# Standard Library
import json
import time
import typing as t
from datetime import UTC, datetime

# Third Party
from litestar import Request, Response, get, post
from litestar.di import Provide
from litestar.background_tasks import BackgroundTask

# Project
from hyperglass.log import log
from hyperglass.state import HyperglassState
from hyperglass.exceptions import HyperglassError
from hyperglass.models.api import Query
from hyperglass.models.data import OutputDataModel
from hyperglass.util.typing import is_type
from hyperglass.execution.main import execute
from hyperglass.models.api.response import QueryResponse
from hyperglass.models.config.params import Params, APIParams
from hyperglass.models.config.devices import Devices, APIDevice

# Local
from .state import get_state, get_params, get_devices
from .tasks import send_webhook
from .fake_output import fake_output

__all__ = (
    "device",
    "devices",
    "queries",
    "info",
    "query",
)


@get("/api/devices/{id:str}", dependencies={"devices": Provide(get_devices)})
async def device(devices: Devices, id: str) -> APIDevice:
    """Retrieve metadata for a specific network device by its unique ID."""
    return devices[id].export_api()


@get("/api/devices", dependencies={"devices": Provide(get_devices)})
async def devices(devices: Devices) -> t.List[APIDevice]:
    """Retrieve the complete list of available network looking glass locations."""
    return devices.export_api()


@get("/api/queries", dependencies={"devices": Provide(get_devices)})
async def queries(devices: Devices) -> t.List[str]:
    """Retrieve all globally available query types (e.g., bgp_route, ping)."""
    return devices.directive_names()


@post("/api/query", dependencies={"_state": Provide(get_state)})
async def query(_state: HyperglassState, request: Request, data: Query) -> QueryResponse:
    """EXECUTION ENGINE: Ingests a validated query and performs the network look-up.

    LIFECYCLE:
    1. Check Redis for a cached response using the query's SHA256 digest.
    2. CACHE HIT: Return cached data and reset expiration timer.
    3. CACHE MISS: Execute the query via the driver (SSH or HTTP).
    4. PERSIST: Store the new response in Redis.
    5. LOG: Trigger an asynchronous webhook task for auditing.
    """

    timestamp = datetime.now(UTC)
    cache = _state.redis
    cache_key = f"hyperglass.query.{data.digest()}"

    _log = log.bind(query=data.summary())
    _log.info("Processing request")

    # ATTEMPT CACHE LOOKUP
    cache_response = cache.get_map(cache_key, "output")
    cached = False
    runtime = 0

    if cache_response:
        _log.bind(cache_key=cache_key).debug("Cache hit")
        cache.expire(cache_key, expire_in=_state.params.cache.timeout)
        cached = True
        timestamp = cache.get_map(cache_key, "timestamp")
    else:
        _log.bind(cache_key=cache_key).debug("Cache miss")
        starttime = time.time()

        # EXECUTION: Perform the real or fake network query
        if _state.params.fake_output:
            output = await fake_output(query_type=data.query_type, structured=data.device.structured_output)
        else:
            output = await execute(data)

        elapsedtime = round(time.time() - starttime, 4)
        runtime = int(round(elapsedtime, 0))

        # SERIALIZATION: Coerce output to JSON if it's a structured model
        raw_output = output.export_dict() if is_type(output, OutputDataModel) else str(output)

        # PERSISTENCE
        cache.set_map_item(cache_key, "output", raw_output)
        cache.set_map_item(cache_key, "timestamp", data.timestamp)
        cache.expire(cache_key, expire_in=_state.params.cache.timeout)

    # FINAL RESPONSE ASSEMBLY
    response_body = {
        "output": cache.get_map(cache_key, "output"),
        "id": cache_key,
        "cached": cached,
        "runtime": runtime,
        "timestamp": timestamp,
        "format": "application/json" if is_type(cache_response, dict) else "text/plain",
        "random": data.random(),
        "level": "success",
    }

    return Response(
        response_body,
        background=BackgroundTask(
            send_webhook, params=_state.params, data=data, request=request, timestamp=timestamp
        ),
    )
