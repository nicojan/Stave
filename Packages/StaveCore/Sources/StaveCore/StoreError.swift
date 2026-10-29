public enum StoreError: Error, Equatable {
    case notFound
    case newerSchema
    case folderTooDeep
    case crossProfileMove
    case lastWorkspace
    case lastProfile
    case containerInUse
    case notPinned
}
