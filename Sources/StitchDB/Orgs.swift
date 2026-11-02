public import Foundation
public import Helpers

// Organizations for your app's users (teams, workspaces; Studio › Authentication › Organizations): create, invite by
// e-mail, roles and the active organization. Calls the `org_*` database functions the platform installs; protect your
// tables with `auth.is_member(org_id)` and `auth.has_role('admin', org_id)`. A request is for the user's active
// organization (the `org_id` claim of the session); send the header `x-org-id: <org id>` (``OrgsClient/headerName``,
// for example in `StitchClientOptions.GlobalOptions.headers`) to make `auth.org_id()` another organization the user
// is a member of.

/// An `org_*` call failed: `code` is the database error code (for example `42501` when the user may not do it).
public struct OrgsError: Error, LocalizedError, Sendable, Equatable {
  public let message: String
  public let status: Int
  public let code: String?

  public init(message: String, status: Int, code: String? = nil) {
    self.message = message
    self.status = status
    self.code = code
  }

  public var errorDescription: String? { message }
}

/// An organization as the signed-in user sees it.
public struct Org: Decodable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let slug: String?
  public let metadata: JSONObject
  /// The signed-in user's role in it: `owner`, `admin`, `member` or one of your custom roles.
  public let role: String
  public let members: Int
  public let createdAt: String?
  /// ``OrgsClient/list()`` only: whether it is the user's active organization (the `org_id` claim).
  public let active: Bool?

  enum CodingKeys: String, CodingKey {
    case id, name, slug, metadata, role, members, active
    case createdAt = "created_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    slug = try c.decodeIfPresent(String.self, forKey: .slug)
    metadata = try c.decodeIfPresent(JSONObject.self, forKey: .metadata) ?? [:]
    role = try c.decodeIfPresent(String.self, forKey: .role) ?? "member"
    members = try c.decodeIfPresent(Int.self, forKey: .members) ?? 0
    createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    active = try c.decodeIfPresent(Bool.self, forKey: .active)
  }
}

/// A member of an organization.
public struct OrgMember: Decodable, Sendable, Equatable {
  public let userID: String
  public let email: String?
  public let name: String?
  public let role: String
  public let joinedAt: String?

  enum CodingKeys: String, CodingKey {
    case email, name, role
    case userID = "user_id"
    case joinedAt = "joined_at"
  }
}

/// An open invite.
public struct OrgInvite: Decodable, Sendable, Equatable {
  public let id: String
  public let email: String
  public let role: String
  public let expiresAt: String?
  public let createdAt: String?
  /// ``OrgsClient/invite(_:email:role:)`` only: put it in your own link if you share invites yourself.
  public let token: String?

  enum CodingKeys: String, CodingKey {
    case id, email, role, token
    case expiresAt = "expires_at"
    case createdAt = "created_at"
  }
}

/// Organizations for your app's users. Use the one on ``StitchClient/orgs``.
///
/// ```swift
/// let team = try await stitchdb.orgs.create(name: "Acme")
/// try await stitchdb.orgs.invite(team.id, email: "ana@acme.test", role: "admin")
/// try await stitchdb.orgs.setActive(team.id)   // the session's org_id / org_role are now for Acme
/// ```
public final class OrgsClient: Sendable {
  /// Calls a database function with named arguments and returns the JSON answer.
  typealias RPC = @Sendable (_ function: String, _ args: JSONObject) async throws -> Data

  /// The request header that picks the organization `auth.org_id()` answers with (when the user is a member).
  public static let headerName = "x-org-id"

  private let rpc: RPC
  private let refresh: @Sendable () async -> Void

  init(rpc: @escaping RPC, refresh: @escaping @Sendable () async -> Void) {
    self.rpc = rpc
    self.refresh = refresh
  }

  private func call(_ function: String, _ args: JSONObject = [:]) async throws -> Data {
    do {
      return try await rpc(function, args)
    } catch let error as PostgrestError {
      let missing =
        error.code == "PGRST202" || error.message.range(of: "Could not find the function", options: .caseInsensitive) != nil
      throw OrgsError(
        message: missing
          ? "Organizations are not turned on for this project (Studio › Authentication › Organizations)" : error.message,
        status: missing ? 404 : 400, code: error.code
      )
    } catch let error as OrgsError {
      throw error
    } catch {
      throw OrgsError(message: error.localizedDescription, status: 0)
    }
  }

  private func decode<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw OrgsError(message: "Unexpected answer: \(error)", status: 200)
    }
  }

  private static func args(_ pairs: [(String, AnyJSON?)]) -> JSONObject {
    var out: JSONObject = [:]
    for (k, v) in pairs { if let v { out[k] = v } }
    return out
  }

  /// Creates an organization; the signed-in user becomes its owner (the session is refreshed for the new claims).
  public func create(name: String, slug: String? = nil, metadata: JSONObject? = nil) async throws -> Org {
    let data = try await call(
      "org_create", Self.args([("name", .string(name)), ("slug", slug.map(AnyJSON.string)), ("metadata", metadata.map(AnyJSON.object))])
    )
    let org = try decode(data, as: Org.self)
    await refresh()
    return org
  }

  /// Renames an organization or changes its slug or metadata (admin).
  public func update(_ org: String, name: String? = nil, slug: String? = nil, metadata: JSONObject? = nil) async throws
    -> Org
  {
    let data = try await call(
      "org_update",
      Self.args([
        ("org", .string(org)), ("name", name.map(AnyJSON.string)), ("slug", slug.map(AnyJSON.string)),
        ("metadata", metadata.map(AnyJSON.object)),
      ])
    )
    return try decode(data, as: Org.self)
  }

  /// Deletes an organization with its memberships and invites (owner).
  public func delete(_ org: String) async throws {
    _ = try await call("org_delete", ["org": .string(org)])
    await refresh()
  }

  /// The signed-in user's organizations.
  public func list() async throws -> [Org] {
    try decode(try await call("org_list"), as: [Org]?.self) ?? []
  }

  /// The members of an organization (any member may list them).
  public func members(_ org: String) async throws -> [OrgMember] {
    try decode(try await call("org_members", ["org": .string(org)]), as: [OrgMember]?.self) ?? []
  }

  /// Invites someone by e-mail (admin): they get an e-mail with a link to your app. Without `role`, the default role
  /// from the settings.
  @discardableResult
  public func invite(_ org: String, email: String, role: String? = nil) async throws -> OrgInvite {
    let data = try await call(
      "org_invite", Self.args([("org", .string(org)), ("email", .string(email)), ("role", role.map(AnyJSON.string))])
    )
    return try decode(data, as: OrgInvite.self)
  }

  /// The open invites of an organization (admin).
  public func invites(_ org: String) async throws -> [OrgInvite] {
    try decode(try await call("org_invites", ["org": .string(org)]), as: [OrgInvite]?.self) ?? []
  }

  /// Withdraws an invite (admin).
  public func revokeInvite(_ invite: String) async throws {
    _ = try await call("org_revoke_invite", ["invite": .string(invite)])
  }

  /// Accepts an invite with the token from the e-mail link; the user must be signed in with the invited address.
  @discardableResult
  public func acceptInvite(token: String) async throws -> Org {
    let org = try decode(try await call("org_accept_invite", ["token": .string(token)]), as: Org.self)
    await refresh()
    return org
  }

  /// Changes a member's role (admin; only owners change admins or make owners).
  public func setRole(_ org: String, userID: String, role: String) async throws {
    _ = try await call("org_set_role", ["org": .string(org), "user_id": .string(userID), "role": .string(role)])
  }

  /// Removes a member (admin).
  public func removeMember(_ org: String, userID: String) async throws {
    _ = try await call("org_remove_member", ["org": .string(org), "user_id": .string(userID)])
  }

  /// Leaves an organization. The last owner transfers ownership or deletes it first.
  public func leave(_ org: String) async throws {
    _ = try await call("org_leave", ["org": .string(org)])
    await refresh()
  }

  /// Makes another member the owner; the signed-in owner becomes an admin.
  public func transferOwnership(_ org: String, to userID: String) async throws {
    _ = try await call("org_transfer_ownership", ["org": .string(org), "user_id": .string(userID)])
  }

  /// Switches the active organization and refreshes the session, so its `org_id` and `org_role` claims are for it.
  public func setActive(_ org: String) async throws {
    _ = try await call("org_set_active", ["org": .string(org)])
    await refresh()
  }
}
