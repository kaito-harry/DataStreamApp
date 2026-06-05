import Foundation
import SwiftProtobuf
import Actr

extension Local_StartDuplexStreamRequest: RpcRequest {
    typealias Response = Local_StartDuplexStreamResponse
    static var routeKey: String { "local.DuplexStreamService.StartDuplexStream" }
}
extension Local_FinishDuplexStreamRequest: RpcRequest {
    typealias Response = Local_FinishDuplexStreamResponse
    static var routeKey: String { "local.DuplexStreamService.FinishDuplexStream" }
}
