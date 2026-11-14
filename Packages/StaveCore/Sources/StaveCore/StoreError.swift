public enum StoreError: Error, Equatable {
    case notFound
    case newerSchema
    case folderTooDeep
    case crossProfileMove
    case lastWorkspace
    case lastProfile
    case containerInUse
    case notPinned
    case backupFailed
    /// An import found the import history different from what the caller saw: another import ran in between.
    case importChanged
}
