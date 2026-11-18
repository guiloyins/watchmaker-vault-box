#pragma once

#include "vault_json.hpp"

namespace vault::protocol {

enum class Direction { device_to_server, server_to_device };
enum class Type {
    unknown,
    hello,
    welcome,
    command,
    command_result,
    snapshot,
    heartbeat_request,
    heartbeat,
    heartbeat_ack,
    box_arm,
    box_disarm,
    box_command,
    box_status,
    box_status_ack,
    box_query,
    box_feedback
};

struct Message {
    json::Error error;
    Type type;
    // Borrowed complete tree, including extensions. Route only schema-known
    // fields and copy approved values before reusing the workspace.
    json::Value value;
    explicit operator bool() const { return error == json::Error::none; }
};

constexpr json::Limits wire_limits(Direction direction) {
    return {direction == Direction::device_to_server ? 4096U : 8192U, 8U};
}

Message validate_v1(json::Value value, Direction direction);
Message decode_v1(std::string_view bytes, Direction direction, json::WorkspaceView workspace);
json::Encoding encode_v1(json::Value value, Direction direction, char* output, std::size_t capacity);

}  // namespace vault::protocol
