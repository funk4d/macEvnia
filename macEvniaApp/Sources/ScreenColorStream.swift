import Foundation

protocol ScreenColorStream: AnyObject {
    var onColors: (([RGBColor]) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start(completion: @escaping (Result<Void, Error>) -> Void)
    func update(profile: AmbilightProfile)
    func stop()
}
