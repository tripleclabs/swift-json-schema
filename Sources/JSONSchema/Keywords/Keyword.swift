import Foundation

public typealias KeywordIdentifier = String

package protocol Keyword: Sendable {
  /// The name of the keyword, such as `type` or `minLength`.
  static var name: KeywordIdentifier { get }

  /// The vocabulary URI that defines this keyword.
  static var vocabulary: String { get }

  var value: JSONValue { get }
  var context: KeywordContext { get }

  init(value: JSONValue, context: KeywordContext)
}

package struct KeywordContext {
  let location: JSONPointer
  let contextReference: ContextReference
  let uri: URL

  var context: Context { contextReference.context }

  package init(
    location: JSONPointer = .init(),
    context: Context = .init(dialect: .draft2020_12),
    uri: URL = .init(fileURLWithPath: #file)
  ) {
    self.init(location: location, contextReference: ContextReference(retaining: context), uri: uri)
  }

  init(location: JSONPointer, contextReference: ContextReference, uri: URL) {
    self.location = location
    self.contextReference = contextReference
    self.uri = uri
  }
}

extension KeywordContext {
  func absoluteKeywordLocation(for pointer: JSONPointer? = nil) -> URL? {
    let pointer = pointer ?? location
    return pointer.absoluteLocation(relativeTo: uri)
  }
}
