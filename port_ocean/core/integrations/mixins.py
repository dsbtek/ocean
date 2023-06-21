import asyncio
from itertools import chain
from typing import Callable, List, Tuple, Awaitable, Any, Dict

from loguru import logger

from port_ocean.clients.port.types import UserAgentType
from port_ocean.context.ocean import PortOceanContext, ocean
from port_ocean.core.handlers import (
    BaseManipulation,
    BasePortAppConfig,
    BaseTransport,
)
from port_ocean.core.handlers.manipulation.base import Diff
from port_ocean.core.handlers.manipulation.jq_manipulation import JQManipulation
from port_ocean.core.handlers.port_app_config.api import APIPortAppConfig
from port_ocean.core.handlers.port_app_config.models import ResourceConfig
from port_ocean.core.handlers.transport.port.transport import HttpPortTransport
from port_ocean.core.models import Entity, Blueprint
from port_ocean.core.utils import validate_result
from port_ocean.types import (
    START_EVENT_LISTENER,
    RESYNC_EVENT_LISTENER,
    IntegrationEventsCallbacks,
    RawObjectDiff,
    ObjectDiff,
)


class EventsMixin:
    def __init__(self) -> None:
        self.event_strategy: IntegrationEventsCallbacks = {
            "start": [],
            "resync": [],
        }

    def on_start(self, func: START_EVENT_LISTENER) -> START_EVENT_LISTENER:
        self.event_strategy["start"].append(func)
        return func

    def on_resync(self, func: RESYNC_EVENT_LISTENER) -> RESYNC_EVENT_LISTENER:
        self.event_strategy["resync"].append(func)
        return func


class HandlerMixin:
    ManipulationHandlerClass: Callable[
        [PortOceanContext], BaseManipulation
    ] = JQManipulation

    AppConfigHandlerClass: Callable[
        [PortOceanContext], BasePortAppConfig
    ] = APIPortAppConfig

    TransportHandlerClass: Callable[
        [PortOceanContext], BaseTransport
    ] = HttpPortTransport

    def __init__(self) -> None:
        self._manipulation: BaseManipulation | None = None
        self._port_app_config_handler: BasePortAppConfig | None = None
        self._transport: BaseTransport | None = None

    @property
    def manipulation(self) -> BaseManipulation:
        if not self._manipulation:
            raise Exception("Integration not started")
        return self._manipulation

    @property
    def port_app_config_handler(self) -> BasePortAppConfig:
        if self._port_app_config_handler is None:
            raise Exception("Integration not started")
        return self._port_app_config_handler

    @property
    def transport(self) -> BaseTransport:
        if not self._transport:
            raise Exception("Integration not started")
        return self._transport

    async def _init_manipulation_instance(self) -> BaseManipulation:
        self._manipulation = self.ManipulationHandlerClass(ocean)
        return self._manipulation

    async def _init_port_app_config_handler_instance(
        self,
    ) -> BasePortAppConfig:
        self._port_app_config_handler = self.AppConfigHandlerClass(ocean)
        return self._port_app_config_handler

    async def _init_transport_instance(self) -> BaseTransport:
        self._transport = self.TransportHandlerClass(ocean)
        return self._transport

    async def initialize_handlers(self) -> None:
        logger.info("Initializing integration components")
        await self._init_manipulation_instance()
        await self._init_port_app_config_handler_instance()
        await self._init_transport_instance()


class SyncMixin(HandlerMixin, EventsMixin):
    def __init__(self) -> None:
        HandlerMixin.__init__(self)
        EventsMixin.__init__(self)

    async def _on_resync(self, kind: str) -> List[Dict[Any, Any]]:
        raise NotImplementedError("on_resync must be implemented")

    async def _calculate_raw(
        self, raw_diff: List[Tuple[ResourceConfig, List[RawObjectDiff]]]
    ) -> List[Diff]:
        logger.info("Calculating diff in entities and blueprints between states")
        return await asyncio.gather(
            *[
                self.manipulation.parse_items(mapping, results)
                for mapping, results in raw_diff
            ]
        )

    async def _run_resync(
        self, resource_config: ResourceConfig
    ) -> Tuple[ResourceConfig, List[Dict[Any, Any]]]:
        logger.info(f"Resyncing {resource_config.kind}")
        tasks: List[Awaitable[List[Dict[Any, Any]]]] = []
        with logger.contextualize(kind=resource_config.kind):
            if self.__class__._on_resync != SyncMixin._on_resync:
                tasks.append(self._on_resync(resource_config.kind))

            for wrapper in self.event_strategy["resync"]:
                tasks.append(wrapper(resource_config.kind))

            logger.info(f"Found {len(tasks)} resync tasks for {resource_config.kind}")
            results: List[Dict[Any, Any]] = list(
                chain.from_iterable(
                    [
                        validate_result(task_result)
                        for task_result in await asyncio.gather(*tasks)
                    ]
                )
            )

            logger.info(f"Triggered {len(tasks)} tasks for {resource_config.kind}")
            return resource_config, results

    async def register(
        self,
        entities: ObjectDiff[Entity],
        blueprints: ObjectDiff[Blueprint],
        user_agent_type: UserAgentType,
    ) -> None:
        await self.transport.update_diff(entities, blueprints, user_agent_type)
        logger.info("Finished registering change")

    async def register_raw(
        self, kind: str, change_state: RawObjectDiff, user_agent_type: UserAgentType
    ) -> None:
        logger.info(f"Registering state for {kind}")
        config = await self.port_app_config_handler.get_port_app_config()
        resource_mappings = [
            resource for resource in config.resources if resource.kind == kind
        ]

        with logger.contextualize(kind=kind):
            logger.info(f"Found {len(resource_mappings)} resources for {kind}")

            objects_diff = await self._calculate_raw(
                [(mapping, [change_state]) for mapping in resource_mappings]
            )

            entities_before, entities_after = tuple(  # type: ignore
                sum(state, [])
                for state in zip(
                    *(
                        (entities_change["before"], entities_change["after"])
                        for entities_change, _ in objects_diff
                    )
                )
            )
            blueprints_before, blueprints_after = tuple(  # type: ignore
                sum(state, [])
                for state in zip(
                    *(
                        (blueprints_change["before"], blueprints_change["after"])
                        for _, blueprints_change in objects_diff
                    )
                )
            )

            await self.register(
                {"before": entities_before, "after": entities_after},
                {"before": blueprints_before, "after": blueprints_after},
                user_agent_type,
            )

    async def sync(
        self,
        entities: List[Entity],
        blueprints: List[Blueprint],
        user_agent_type: UserAgentType,
    ) -> None:
        current_entities = await ocean.port_client.search_entities(user_agent_type)
        current_blueprints = []

        entities_diff: ObjectDiff[Entity] = {
            "before": current_entities,
            "after": entities,
        }
        blueprints_diff: ObjectDiff[Blueprint] = {
            "before": current_blueprints,
            "after": blueprints,
        }

        await self.transport.update_diff(
            entities_diff, blueprints_diff, user_agent_type
        )
        logger.info("Finished syncing change")
