/// Stable imports for service callers. Independent modules own transport,
/// profile endpoints, startup coordination, frontend bridging and worker state.
library;

export 'application_service.dart' show ApplicationService;
export 'service_client.dart' show ServiceClient, cancellableAnswers;
export 'service_connection.dart' show ServiceConnection;
export 'service_framing.dart' show maxServiceMessage;
export 'service_frontend.dart'
    show IsolatedApplicationService, runApplicationWorkerZone;
export 'service_gates.dart' show serviceGatesEnabled, serviceGate;
export 'service_ownership.dart'
    show
        AnotherProfileServing,
        anotherProfileMessage,
        UnverifiableServiceOwner,
        readPosixLockHolders,
        servesAnotherProfile,
        EndpointRecord,
        EndpointAbsent,
        EndpointValid,
        EndpointInvalid,
        readEndpointRecord,
        serviceEndpoint,
        ServiceOwnershipContended,
        ServiceLaunchWithdrawn;
export 'service_startup.dart'
    show
        ServiceStartup,
        closingOwnerEndedProbe,
        awaitProfileRelease,
        requireProfileRelease,
        profileReleased,
        profileLeftUnclean,
        serviceLaunchCommand,
        writeServiceStartupEnvironment,
        recordServiceStartupFailure,
        ensureService,
        ensureServiceSnapshot;
