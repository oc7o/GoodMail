import Foundation

// Standard methods from RFC 8620 §5, generic over the object type.

// MARK: /get

public struct GetRequest<Object: JMAPObject>: MethodCall {
    public typealias Response = GetResponse<Object>
    public static var name: String { "\(Object.typeName)/get" }
    public static var using: [String] { [Object.capability] }

    public var accountId: String
    public var ids: IDs
    public var properties: [String]?

    public init(accountId: String, ids: IDs = .all, properties: [String]? = nil) {
        self.accountId = accountId
        self.ids = ids
        self.properties = properties
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, ids, properties
        case idsRef = "#ids"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(ids, forKey: .ids, referenceKey: .idsRef)
        try container.encodeIfPresent(properties, forKey: .properties)
    }
}

public struct GetResponse<Object: JMAPObject>: Decodable, Sendable {
    public let accountId: String
    public let state: String
    public let list: [Object]
    public let notFound: [String]
}

// MARK: /changes

public struct ChangesRequest<Object: JMAPObject>: MethodCall {
    public typealias Response = ChangesResponse
    public static var name: String { "\(Object.typeName)/changes" }
    public static var using: [String] { [Object.capability] }

    public var accountId: String
    public var sinceState: String
    public var maxChanges: Int?

    public init(accountId: String, sinceState: String, maxChanges: Int? = nil) {
        self.accountId = accountId
        self.sinceState = sinceState
        self.maxChanges = maxChanges
    }
}

public struct ChangesResponse: Decodable, Sendable {
    public let accountId: String
    public let oldState: String
    public let newState: String
    public let hasMoreChanges: Bool
    public let created: [String]
    public let updated: [String]
    public let destroyed: [String]
    /// Only returned by `Mailbox/changes` (RFC 8621 §2.2).
    public let updatedProperties: [String]?
}

// MARK: /query

/// A JMAP FilterOperator tree over a type-specific condition.
public indirect enum Filter<Condition: Encodable & Sendable>: Encodable, Sendable {
    case condition(Condition)
    case and([Filter])
    case or([Filter])
    case not([Filter])

    private enum CodingKeys: String, CodingKey { case `operator`, conditions }

    public func encode(to encoder: Encoder) throws {
        let (op, conditions): (String, [Filter])
        switch self {
        case .condition(let condition):
            try condition.encode(to: encoder)
            return
        case .and(let filters): (op, conditions) = ("AND", filters)
        case .or(let filters): (op, conditions) = ("OR", filters)
        case .not(let filters): (op, conditions) = ("NOT", filters)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(op, forKey: .operator)
        try container.encode(conditions, forKey: .conditions)
    }
}

public struct Comparator: Encodable, Sendable, Equatable {
    public var property: String
    public var isAscending: Bool
    public var collation: String?
    /// Required when `property` is `hasKeyword` / `someInThreadHaveKeyword` etc.
    public var keyword: String?

    public init(property: String, isAscending: Bool = true, collation: String? = nil, keyword: String? = nil) {
        self.property = property
        self.isAscending = isAscending
        self.collation = collation
        self.keyword = keyword
    }
}

/// A type that supports `/query`.
public protocol QueryableObject: JMAPObject {
    associatedtype FilterCondition: Encodable & Sendable
}

public struct QueryRequest<Object: QueryableObject>: MethodCall {
    public typealias Response = QueryResponse
    public static var name: String { "\(Object.typeName)/query" }
    public static var using: [String] { [Object.capability] }

    public var accountId: String
    public var filter: Filter<Object.FilterCondition>?
    public var sort: [Comparator]?
    public var position: Int?
    public var anchor: String?
    public var anchorOffset: Int?
    public var limit: Int?
    public var calculateTotal: Bool?
    /// `Email/query` only: return one email per thread.
    public var collapseThreads: Bool?

    public init(
        accountId: String,
        filter: Filter<Object.FilterCondition>? = nil,
        sort: [Comparator]? = nil,
        position: Int? = nil,
        anchor: String? = nil,
        anchorOffset: Int? = nil,
        limit: Int? = nil,
        calculateTotal: Bool? = nil,
        collapseThreads: Bool? = nil
    ) {
        self.accountId = accountId
        self.filter = filter
        self.sort = sort
        self.position = position
        self.anchor = anchor
        self.anchorOffset = anchorOffset
        self.limit = limit
        self.calculateTotal = calculateTotal
        self.collapseThreads = collapseThreads
    }
}

public struct QueryResponse: Decodable, Sendable {
    public let accountId: String
    public let queryState: String
    public let canCalculateChanges: Bool
    public let position: Int
    public let ids: [String]
    public let total: Int?
    public let limit: Int?
}

// MARK: /set

/// A type that supports `/set`, with the shape used to create new objects.
public protocol SettableObject: JMAPObject {
    associatedtype Create: Encodable & Sendable
}

public struct SetRequest<Object: SettableObject>: MethodCall {
    public typealias Response = SetResponse
    public static var name: String { "\(Object.typeName)/set" }
    public static var using: [String] { [Object.capability] }

    public var accountId: String
    public var ifInState: String?
    /// Keyed by a client-chosen creation id, referencable as `#creationId`.
    public var create: [String: Object.Create]?
    public var update: [String: PatchObject]?
    public var destroy: [String]?

    public init(
        accountId: String,
        ifInState: String? = nil,
        create: [String: Object.Create]? = nil,
        update: [String: PatchObject]? = nil,
        destroy: [String]? = nil
    ) {
        self.accountId = accountId
        self.ifInState = ifInState
        self.create = create
        self.update = update
        self.destroy = destroy
    }
}

public struct SetResponse: Decodable, Sendable {
    public let accountId: String
    public let oldState: String?
    public let newState: String
    /// Server-set properties of created objects, keyed by creation id.
    public let created: [String: JSONValue]?
    public let updated: [String: JSONValue?]?
    public let destroyed: [String]?
    public let notCreated: [String: SetError]?
    public let notUpdated: [String: SetError]?
    public let notDestroyed: [String: SetError]?

    /// Decodes the server-returned properties of a created object.
    public func created<T: Decodable>(_ creationId: String, as type: T.Type) throws -> T? {
        guard let value = created?[creationId] else { return nil }
        return try BatchResponse.decode(T.self, from: value)
    }
}
