#include "vault_protocol.hpp"

#include <array>
#include <cstdio>

namespace {

using namespace vault;
using protocol::Direction;
using protocol::Type;
using json::Error;

json::Workspace<8192> workspace;
std::array<char, 8192> bytes;
int failed = 0;

void expect(bool ok, const char* reason) {
    if (!ok) {
        std::fprintf(stderr, "%s\n", reason);
        ++failed;
    }
}

constexpr auto device = Direction::device_to_server;
constexpr auto server = Direction::server_to_device;

void routing() {
    constexpr auto raw = R"({"v":1e0,"type":"hello","device_id":"cyd-a","boot_id":"boot-a",
      "device_class":"controller","firmware_version":"test","extra":{"active":true,"n":1e999999},
      "capabilities":{"touch":true,"screen_width":320,"screen_height":240.0,
      "max_message_bytes":8192,"can_move_box":true}})";
    const auto hello = protocol::decode_v1(raw, device, workspace.view());
    expect(hello && hello.type == Type::hello, "valid controller hello must decode");
    expect(hello.value.get("capabilities").get("screen_height").integer() == 240,
           "borrowed view must expose exact normalized integers");
    const auto encoded = protocol::encode_v1(hello.value, device, bytes.data(), bytes.size());
    expect(static_cast<bool>(encoded), "valid controller hello must encode");
    expect(encoded.bytes.find("240.0") == encoded.bytes.npos &&
           encoded.bytes.find("can_move_box") == encoded.bytes.npos &&
           encoded.bytes.find("extra") == encoded.bytes.npos,
           "encoder must allowlist both levels and normalize integers");
    const auto roundtrip = protocol::decode_v1(encoded.bytes, device, workspace.view());
    expect(roundtrip && roundtrip.type == Type::hello, "encoded hello must decode");
    expect(protocol::decode_v1(raw, server, workspace.view()).error == Error::shape,
           "device-only hello must be rejected in the server direction");
}

void strict_fields() {
    constexpr auto raw = R"({"v":1,"type":"command","connection_id":"c","session_id":"s",
      "command_seq":1,"action":"release_role","role":"b","control_epoch":1,"payload":{}})";
    expect(protocol::decode_v1(raw, device, workspace.view()).type == Type::command,
           "valid release-role command must decode");
    constexpr auto invalid = R"({"v":1,"type":"command","connection_id":"c","session_id":"s",
      "command_seq":1,"action":"release_role","role":"b","control_epoch":1,"payload":{"ext":null}})";
    expect(protocol::decode_v1(invalid, device, workspace.view()).error == Error::shape,
           "strict command payload must reject extensions");

    constexpr auto challenge = R"({"v":1,"type":"heartbeat_request","connection_id":"c",
      "heartbeat_seq":1})";
    const auto message = protocol::decode_v1(challenge, server, workspace.view());
    expect(message && message.type == Type::heartbeat_request,
           "server challenge must decode");
    expect(protocol::encode_v1(message.value, server, bytes.data(), 1).error == Error::resource,
           "small outbound buffer must fail without partial bytes");
}

}  // namespace

int main() {
    routing();
    strict_fields();
    return failed != 0;
}
