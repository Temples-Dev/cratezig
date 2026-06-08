pub const Error = error{
    // 404
    ContainerNotFound,
    ImageNotFound,
    NetworkNotFound,
    VolumeNotFound,
    ExecNotFound,

    // 409
    ContainerAlreadyRunning,
    ContainerNotRunning,
    ContainerBeingRemoved,
    ContainerNameInUse,
    ImageInUse,
    NetworkHasEndpoints,
    VolumeInUse,

    // 400
    InvalidParameter,
    NoCommandSpecified,
    UnsupportedPlatform,

    // 500
    RuntimeError,
    StorageError,
    NetworkError,

    //
    SubnetExhausted,
};

pub fn httpStatus(err: Error) u16 {
    return switch (err) {
        .ContainerAlreadyRunning => 304,
        .ContainerNotFound, .ImageNotFound, .NetworkNotFound, .VolumeNotFound, .ExecNotFound => 404,
        .ContainerAlreadyRunning,
        .ContainerNotRunning,
        .ContainerBeingRemoved,
        .ContainerNameInUse,
        .ImageInUse,
        .NetworkHasEndpoints,
        .VolumeInUse,
        => 409,
        .InvalidParameter, .NoCommandSpecified, .UnsupportedPlatform => 400,
        else => 500,
    };
}
