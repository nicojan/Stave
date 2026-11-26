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
    /// A profile or container name that is empty once trimmed.
    case blankName
    /// A container colour outside the shared palette (and not the colour the container already has).
    case invalidColour
    /// An import found the import history different from what the caller saw: another import ran in between.
    case importChanged
}
