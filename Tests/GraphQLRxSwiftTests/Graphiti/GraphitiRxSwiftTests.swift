import Graphiti
import GraphQL
@testable import GraphQLRxSwift
import NIO
import RxSwift
import XCTest

let pubsub = PublishSubject<User>()

struct ID: Codable {
    let id: String

    init(_ id: String) {
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        id = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

struct User: Codable {
    let id: String
    let name: String?

    init(id: String, name: String?) {
        self.id = id
        self.name = name
    }

    init(_ input: UserInput) {
        id = input.id
        name = input.name
    }

    func toEvent(context _: HelloContext, arguments _: NoArguments) throws -> UserEvent {
        return UserEvent(user: self)
    }
}

struct UserInput: Codable {
    let id: String
    let name: String?
}

struct UserEvent: Codable {
    let user: User
}

final class HelloContext {
    func hello() -> String {
        "world"
    }
}

struct HelloResolver {
    func hello(context: HelloContext, arguments _: NoArguments) -> String {
        context.hello()
    }

    func asyncHello(
        context: HelloContext,
        arguments _: NoArguments,
        group: EventLoopGroup
    ) -> EventLoopFuture<String> {
        group.next().makeSucceededFuture(context.hello())
    }

    struct FloatArguments: Codable {
        let float: Float
    }

    func getFloat(context _: HelloContext, arguments: FloatArguments) -> Float {
        arguments.float
    }

    struct IDArguments: Codable {
        let id: ID
    }

    func getId(context _: HelloContext, arguments: IDArguments) -> ID {
        arguments.id
    }

    func getUser(context _: HelloContext, arguments _: NoArguments) -> User {
        User(id: "123", name: "John Doe")
    }

    struct AddUserArguments: Codable {
        let user: UserInput
    }

    func addUser(context _: HelloContext, arguments: AddUserArguments) -> User {
        User(arguments.user)
    }

    func subscribeUser(context _: HelloContext, arguments _: NoArguments) -> EventStream<User> {
        pubsub.toEventStream()
    }
}

struct HelloAPI: API {
    let resolver = HelloResolver()
    let context = HelloContext()

    let schema = try! Schema<HelloResolver, HelloContext> {
        Scalar(Float.self)
            .description("The `Float` scalar type represents signed double-precision fractional values as specified by [IEEE 754](http://en.wikipedia.org/wiki/IEEE_floating_point).")

        Scalar(ID.self)
            .description("The `ID` scalar type represents a unique identifier.")

        Type(User.self) {
            Field("id", at: \.id)
            Field("name", at: \.name)
        }

        Input(UserInput.self) {
            InputField("id", at: \.id)
            InputField("name", at: \.name)
        }

        Type(UserEvent.self) {
            Field("user", at: \.user)
        }

        Query {
            Field("hello", at: HelloResolver.hello)
            Field("asyncHello", at: HelloResolver.asyncHello)

            Field("float", at: HelloResolver.getFloat) {
                Argument("float", at: \.float)
            }

            Field("id", at: HelloResolver.getId) {
                Argument("id", at: \.id)
            }

            Field("user", at: HelloResolver.getUser)
        }

        Mutation {
            Field("addUser", at: HelloResolver.addUser) {
                Argument("user", at: \.user)
            }
        }

        Subscription {
            SubscriptionField("subscribeUser", as: User.self, atSub: HelloResolver.subscribeUser)
            SubscriptionField("subscribeUserEvent", at: User.toEvent, atSub: HelloResolver.subscribeUser)
        }
    }
}

class HelloWorldTests: XCTestCase {
    private let api = HelloAPI()
    private var group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    deinit {
        try? self.group.syncShutdownGracefully()
    }

    /// Tests subscription when the sourceEventStream type matches the resolved type (i.e. the normal resolution function should just short-circuit to the sourceEventStream object)
    func testSubscriptionSelf() throws {
        let disposeBag = DisposeBag()

        let request = """
        subscription {
            subscribeUser {
                id
                name
            }
        }
        """

        let subscriptionResult = try api.subscribe(
            request: request,
            context: api.context,
            on: group
        ).wait()
        guard let subscription = subscriptionResult.stream else {
            XCTFail(subscriptionResult.errors.description)
            return
        }
        guard let stream = subscription as? ObservableSubscriptionEventStream else {
            XCTFail("stream isn't ObservableSubscriptionEventStream")
            return
        }

        let expectation = XCTestExpectation()

        var currentResult = GraphQLResult()
        let _ = stream.observable.subscribe { event in
            let resultFuture = event.element!
            resultFuture.whenSuccess { result in
                currentResult = result
                expectation.fulfill()
            }
            resultFuture.whenFailure { _ in
                XCTFail()
            }
        }.disposed(by: disposeBag)

        pubsub.onNext(User(id: "124", name: "Jerry"))

        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(currentResult, GraphQLResult(data: [
            "subscribeUser": [
                "id": "124",
                "name": "Jerry",
            ],
        ]))
    }

    /// Tests subscription when the sourceEventStream type does not match the resolved type (i.e. there is a non-trivial resolution function that transforms the sourceEventStream object)
    func testSubscriptionEvent() throws {
        let disposeBag = DisposeBag()

        let request = """
        subscription {
            subscribeUserEvent {
                user {
                    id
                    name
                }
            }
        }
        """

        let subscriptionResult = try api.subscribe(
            request: request,
            context: api.context,
            on: group
        ).wait()
        guard let subscription = subscriptionResult.stream else {
            XCTFail(subscriptionResult.errors.description)
            return
        }
        guard let stream = subscription as? ObservableSubscriptionEventStream else {
            XCTFail("stream isn't ObservableSubscriptionEventStream")
            return
        }

        let expectation = XCTestExpectation()

        var currentResult = GraphQLResult()
        let _ = stream.observable.subscribe { event in
            let resultFuture = event.element!
            resultFuture.whenSuccess { result in
                currentResult = result
                expectation.fulfill()
            }
            resultFuture.whenFailure { _ in
                XCTFail()
            }
        }.disposed(by: disposeBag)

        pubsub.onNext(User(id: "124", name: "Jerry"))

        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(currentResult, GraphQLResult(data: [
            "subscribeUserEvent": [
                "user": [
                    "id": "124",
                    "name": "Jerry",
                ],
            ],
        ]))
    }
}
