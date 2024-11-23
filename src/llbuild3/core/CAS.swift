//===- CAS.swift ----------------------------------------------*- Swift -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

public protocol TCASDatabase {
  /// Check if the database contains the given `id`.
  func contains(_ id: TCASObjectID) async throws -> Bool

  /// Get the object corresponding to the given `id`.
  ///
  /// - Parameters:
  ///   - id: The id of the object to look up
  /// - Returns: The object, or nil if not present in the database.
  func get(_ id: TCASObjectID) async throws -> TCASObject?

  /// Calculate the DataID for the given CAS object.
  ///
  /// The implementation *MUST* return a valid content-address, such
  /// that a subsequent call to `put(...` will return an identical
  /// `identify`. This method should be implemented as efficiently as possible,
  /// ideally locally.
  ///
  /// NOTE: The implementations *MAY* store the content, as if it were `put`.
  /// Clients *MAY NOT* assume the data has been written.
  ///
  ///
  /// - Parameters:
  ///    - refs: The list of objects references.
  ///    - data: The object contents.
  /// - Returns: The id representing the combination of contents and refs.
  func identify(_ obj: TCASObject) throws -> TCASObjectID

  /// Store an object.
  ///
  /// - Parameters:
  ///    - refs: The list of objects references.
  ///    - data: The object contents.
  /// - Returns: The id representing the combination of contents and refs.
  func put(_ obj: TCASObject) async throws -> TCASObjectID
}

extension TCASDatabase {
  func extCASDatabase() -> llbuild3.core.ExtCASDatabase {
    var extCASDB = llbuild3.core.ExtCASDatabase()
    extCASDB.ctx = Unmanaged.passRetained(self as AnyObject).toOpaque()

    extCASDB.containsFn = { ctx, id, handler in
      let casid = TCASObjectID.with { casid in
        id.withUnsafeBytes { bp in
          casid.bytes = Data(buffer: bp.bindMemory(to: CChar.self))
        }
      }

      let sp = Unmanaged<AnyObject>.fromOpaque(ctx!).takeUnretainedValue() as! TCASDatabase
      Task {
        do {
          handler(try await sp.contains(casid), std.string())
          return
        } catch {
          let err: TError
          if let terr = error as? TError {
            err = terr
          } else {
            err = TError.with {
              $0.type = .client
              $0.code = llbuild3.core.Unknown.rawValue
              $0.description_p = "\(error)"
            }
          }
          guard let bytes = try? err.serializedData() else {
            handler(false, std.string("failed error serialization"))
            return
          }

          handler(false, std.string(fromData: bytes))
        }
      }
    }

    extCASDB.getFn = { ctx, id, handler in
      let casid = TCASObjectID.with { casid in
        id.withUnsafeBytes { bp in
          casid.bytes = Data(buffer: bp.bindMemory(to: CChar.self))
        }
      }

      let sp = Unmanaged<AnyObject>.fromOpaque(ctx!).takeUnretainedValue() as! TCASDatabase
      Task {
        do {
          if let obj = try await sp.get(casid) {
            guard let bytes = try? obj.serializedData() else {
              handler(std.string(), std.string("failed error serialization"))
              return
            }

            handler(std.string(fromData: bytes), std.string())
            return
          }

          let err = TError.with {
            $0.type = .cas
            $0.code = llbuild3.core.ObjectNotFound.rawValue
          }
          guard let bytes = try? err.serializedData() else {
            handler(std.string(), std.string("failed error serialization"))
            return
          }

          handler(std.string(), std.string(fromData: bytes))
          return
        } catch {
          let err: TError
          if let terr = error as? TError {
            err = terr
          } else {
            err = TError.with {
              $0.type = .cas
              $0.code = llbuild3.core.UnknownCASError.rawValue
              $0.description_p = "\(error)"
            }
          }
          guard let bytes = try? err.serializedData() else {
            handler(std.string(), std.string("failed error serialization"))
            return
          }

          handler(std.string(), std.string(fromData: bytes))
        }
      }
    }

    extCASDB.putFn = { ctx, opb, handler in
      let obj: TCASObject
      do {
        obj = try TCASObject(serializedBytes: opb)
      } catch {
        let err = TError.with {
          $0.type = .engine
          $0.code = llbuild3.core.InternalProtobufSerialization.rawValue
          $0.description_p = "cas put"
        }
        guard let bytes = try? err.serializedData() else {
          return
        }
        handler(std.string(), std.string(fromData: bytes))
        return
      }


      let sp = Unmanaged<AnyObject>.fromOpaque(ctx!).takeUnretainedValue() as! TCASDatabase
      Task {
        do {
          let casid = try await sp.put(obj)
          handler(std.string(fromData: casid.bytes), std.string())
          return
        } catch {
          let err: TError
          if let terr = error as? TError {
            err = terr
          } else {
            err = TError.with {
              $0.type = .cas
              $0.code = llbuild3.core.UnknownCASError.rawValue
              $0.description_p = "\(error)"
            }
          }
          guard let bytes = try? err.serializedData() else {
            handler(std.string(), std.string("failed error serialization"))
            return
          }

          handler(std.string(), std.string(fromData: bytes))
        }
      }
    }

    extCASDB.identifyFn = { ctx, opb in
      let obj: TCASObject
      do {
        obj = try TCASObject(serializedBytes: opb)
      } catch {
        // FIXME: propagate error
        return std.string()
      }

      let sp = Unmanaged<AnyObject>.fromOpaque(ctx!).takeUnretainedValue() as! TCASDatabase
      do {
        let casid = try sp.identify(obj)
        return std.string(fromData: casid.bytes)
      } catch {
        // FIXME: propagate error
        return std.string()
      }
    }

    return extCASDB;
  }
}
