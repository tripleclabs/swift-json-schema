import Foundation
import Testing

@testable import JSONSchema

#if canImport(Darwin)
  import Darwin
#endif

/// Regression tests for reference cycles between `Context`, the schemas it
/// caches for `$ref` resolution, and the schemas that hold the context.
///
/// Each test builds and exercises a schema inside a scope, keeps only weak
/// references to the schema's context and to a class instance owned by the
/// schema tree, and asserts both are released once the scope exits.
struct SchemaLifetimeTests {
  /// Observes the lifetime of a schema's context and of its schema tree.
  private struct Probe {
    weak var context: Context?
    weak var tree: AnyObject?
  }

  /// A class instance reachable only through the schema tree: the format
  /// validator is stored in the context, so `tree` going away proves the
  /// whole context graph (registry, cached schemas, resolved references) was
  /// freed rather than merely the outer `Schema` value.
  private final class Marker: FormatValidator, @unchecked Sendable {
    let formatName = "marker"
    func validate(_ value: String) -> Bool { true }
  }

  private func probe(_ build: (Marker) throws -> Schema) rethrows -> Probe {
    let marker = Marker()
    let schema = try build(marker)
    return Probe(context: schema.context, tree: marker)
  }

  @Test func plainSchemaIsReleased() throws {
    let probe = try probe { marker in
      let schema = try Schema(
        instance: #"{"type":"object","properties":{"a":{"type":"string","format":"marker"}}}"#,
        formatValidators: [marker]
      )
      #expect(schema.validate(["a": "x"]).isValid)
      return schema
    }
    #expect(probe.context == nil)
    #expect(probe.tree == nil)
  }

  @Test func schemaWithReferencesIsReleased() throws {
    let probe = try probe { marker in
      let schema = try Schema(
        instance: """
          {
            "$id": "https://example.com/tree",
            "$ref": "#/$defs/node",
            "$defs": {
              "node": {
                "type": "object",
                "properties": {
                  "name": { "type": "string", "format": "marker" },
                  "children": { "type": "array", "items": { "$ref": "#/$defs/node" } },
                  "self": { "$ref": "https://example.com/tree" },
                  "anchored": { "$ref": "#leaf" }
                }
              },
              "leaf": { "$anchor": "leaf", "type": "integer" }
            }
          }
          """,
        formatValidators: [marker]
      )
      let valid: JSONValue = [
        "name": "root",
        "children": [["name": "child", "children": []]],
        "anchored": 1,
      ]
      #expect(schema.validate(valid).isValid)
      #expect(!schema.validate(["children": [["name": 1]]]).isValid)
      return schema
    }
    #expect(probe.context == nil)
    #expect(probe.tree == nil)
  }

  @Test func schemaWithDynamicReferencesIsReleased() throws {
    let probe = try probe { marker in
      let schema = try Schema(
        instance: """
          {
            "$id": "https://example.com/strict-tree",
            "$dynamicAnchor": "node",
            "$ref": "https://example.com/tree",
            "unevaluatedProperties": false,
            "$defs": {
              "tree": {
                "$id": "https://example.com/tree",
                "$dynamicAnchor": "node",
                "type": "object",
                "properties": {
                  "data": { "type": "string", "format": "marker" },
                  "children": { "type": "array", "items": { "$dynamicRef": "#node" } }
                }
              }
            }
          }
          """,
        formatValidators: [marker]
      )
      #expect(schema.validate(["children": [["data": "x"]]]).isValid)
      #expect(!schema.validate(["children": [["daat": "x"]]]).isValid)
      return schema
    }
    #expect(probe.context == nil)
    #expect(probe.tree == nil)
  }

  @Test func metaSchemaValidationReleasesSchemas() throws {
    weak var metaContext: Context?
    let probe = try probe { marker in
      let schema = try Schema(
        instance: #"{"type":"object","properties":{"a":{"type":"string","format":"marker"}}}"#,
        formatValidators: [marker]
      )
      #expect(try schema.validateAgainstMetaSchema().isValid)
      let metaSchema = try Dialect.draft2020_12.loadMetaSchema()
      metaContext = metaSchema.context
      #expect(metaSchema.validate(schema.rawSchema).isValid)
      return schema
    }
    #expect(probe.context == nil)
    #expect(probe.tree == nil)
    #expect(metaContext == nil)
  }

  #if canImport(Darwin)
    /// Resolved `$ref` targets hold no user object a weak reference could observe,
    /// so this measures the heap instead. Each schema carries a 256 KiB string, so a
    /// resolved subtree kept alive by a cycle (here: a cached resource whose `$ref`s
    /// resolve back to itself) leaks that string on every iteration, far above allocator
    /// noise from tests running concurrently.
    @Test func selfReferencingSchemasDoNotAccumulate() throws {
      func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
      }
      let payload = String(repeating: "x", count: 1 << 18)
      func run() throws {
        let schema = try Schema(
          instance: """
            {
              "$id": "https://example.com/self",
              "description": "\(payload)",
              "type": "object",
              "properties": {
                "child": { "$ref": "https://example.com/self" },
                "root": { "$ref": "#" },
                "list": { "type": "array", "items": { "$ref": "#/properties/child" } }
              }
            }
            """
        )
        let instance: JSONValue = [
          "child": ["child": ["root": ["list": [["child": [:]]]]]],
          "root": ["list": [["root": [:]]]],
        ]
        #expect(schema.validate(instance).isValid)
      }
      let iterations = 40
      try run()
      let before = heapInUse()
      for _ in 0 ..< iterations { try run() }
      let growth = heapInUse() - before
      #expect(
        growth < (iterations << 18) / 4,
        "heap grew by \(growth) bytes over \(iterations) schemas"
      )
    }
  #endif

  @Test func referencedSchemasOutliveTheirResolutionScope() throws {
    // A schema handed out to the caller keeps everything it needs alive on its
    // own: references resolved through the context's cache keep working after
    // every other reference to the context has gone.
    let schema = try {
      try Schema(
        instance: """
          {
            "$ref": "#/$defs/list",
            "$defs": {
              "list": { "type": "array", "items": { "$ref": "#/$defs/item" } },
              "item": { "type": "integer" }
            }
          }
          """
      )
    }()
    #expect(schema.validate([1, 2, 3]).isValid)
    #expect(!schema.validate([1, "two"]).isValid)
    #expect(try schema.validateAgainstMetaSchema().isValid)
  }
}
