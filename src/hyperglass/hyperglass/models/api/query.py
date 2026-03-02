"""Input query validation model.

Defines the Pydantic models used to validate and transform user queries
received via the API or CLI. It integrates with the InputPluginManager
to apply platform-specific transformations.
"""

# Standard Library
import typing as t
import hashlib
import secrets
from datetime import datetime

# Third Party
from pydantic import BaseModel, ConfigDict, field_validator, StringConstraints
from typing_extensions import Annotated

# Project
from hyperglass.log import log
from hyperglass.util import snake_to_camel, repr_from_attrs
from hyperglass.state import use_state
from hyperglass.plugins import InputPluginManager
from hyperglass.exceptions.public import InputInvalid, QueryTypeNotFound, QueryLocationNotFound
from hyperglass.exceptions.private import InputValidationError

# Local
from ..config.devices import Device

# TYPING: Strict string constraints for query parameters
QueryLocation = Annotated[str, StringConstraints(strict=True, min_length=1, strip_whitespace=True)]
QueryTarget = Annotated[str, StringConstraints(min_length=1, strip_whitespace=True)]
QueryType = Annotated[str, StringConstraints(strict=True, min_length=1, strip_whitespace=True)]


class SimpleQuery(BaseModel):
    """A simple representation of a post-validated query.
    Used for logging and summarization.
    """

    query_location: str
    query_target: t.Union[t.List[str], str]
    query_type: str

    def __repr_name__(self) -> str:
        """Alias SimpleQuery to Query for clarity in logging."""
        return "Query"


class Query(BaseModel):
    """Primary validation model for user-supplied query parameters."""

    model_config = ConfigDict(extra="allow", alias_generator=snake_to_camel, populate_by_name=True)

    # query_location maps to a Device name/id
    query_location: QueryLocation

    # query_target is the IP, Prefix, or AS-Path to query
    query_target: t.Union[t.List[QueryTarget], QueryTarget]

    # query_type maps to a Directive id (e.g. bgp_route)
    query_type: QueryType
    _kwargs: t.Dict[str, t.Any]

    def __init__(self, **data) -> None:
        """Initialize the query and perform automated validation/transformation.
        
        Initialization sequence:
        1. Set UTC timestamp.
        2. Resolve the matching Directive for the requested query_type.
        3. Validate the query target against the directive rules and plugins.
        4. Apply input transformations (e.g., converting Cisco AS-Paths to BIRD format).
        """
        super().__init__(**data)
        self._kwargs = data
        self.timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")

        state = use_state()
        self._state = state

        # Match the query_type against the device's supported directives
        query_directives = self.device.directives.matching(self.query_type)

        if len(query_directives) < 1:
            raise QueryTypeNotFound(query_type=self.query_type)

        self.directive = query_directives[0]

        self._input_plugin_manager = InputPluginManager()

        try:
            self.validate_query_target()
        except InputValidationError as err:
            raise InputInvalid(**err.kwargs) from err

        # TRANSFORM: Apply registered input plugins to the target
        self.query_target = self.transform_query_target()

    def summary(self) -> SimpleQuery:
        """Summarized and post-validated model of a Query."""
        return SimpleQuery(
            query_location=self.query_location,
            query_target=self.query_target,
            query_type=self.query_type,
        )

    def __repr__(self) -> str:
        """Represent only the query fields."""
        return repr_from_attrs(self, ("query_location", "query_type", "query_target"))

    def __str__(self) -> str:
        """Alias __str__ to __repr__."""
        return repr(self)

    def digest(self) -> str:
        """Create SHA256 hash digest of model representation.
        Used as a cache key for query responses.
        """
        return hashlib.sha256(repr(self).encode()).hexdigest()

    def random(self) -> str:
        """Create a random string to prevent client or proxy caching."""
        return hashlib.sha256(
            secrets.token_bytes(8) + repr(self).encode() + secrets.token_bytes(8)
        ).hexdigest()

    def validate_query_target(self) -> None:
        """Validate a query target after all fields/relationships have been initialized.
        
        Runs both the core directive validation (regex/rules) and any 
        active input plugins.
        """
        # Run config/rule-based validations.
        self.directive.validate_target(self.query_target)
        # Run plugin-based validations.
        self._input_plugin_manager.validate(query=self)
        log.bind(query=self.summary()).debug("Validation passed")

    def transform_query_target(self) -> t.Union[t.List[str], str]:
        """Transform a query target based on defined plugins.
        This handles NOS-specific requirements like Juniper AS-Path formatting.
        """
        return self._input_plugin_manager.transform(query=self)

    def dict(self) -> t.Dict[str, t.Union[t.List[str], str]]:
        """Include only public fields."""
        return super().model_dump(include={"query_location", "query_target", "query_type"})

    @property
    def device(self) -> Device:
        """Get this query's device object by resolving query_location from global state."""
        return self._state.devices[self.query_location]

    @field_validator("query_location")
    def validate_query_location(cls, value):
        """Ensure query_location exists in the configured device inventory."""

        devices = use_state("devices")

        if not devices.valid_id_or_name(value):
            raise QueryLocationNotFound(location=value)

        return value

    @field_validator("query_type")
    def validate_query_type(cls, value: t.Any):
        """Ensure the requested query type exists on AT LEAST ONE configured device."""
        devices = use_state("devices")
        if any((device.has_directives(value) for device in devices)):
            return value

        raise QueryTypeNotFound(query_type=value)
