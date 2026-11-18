#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <string_view>

namespace vault {
enum class FrameResult { incomplete, message, control, closed, invalid, overflow };
enum class ReceiveKind : uint8_t { connected, text };

struct ReceiveEvent {
    uint64_t received_ms{};
    uint32_t generation{};
    uint16_t size{};
    ReceiveKind kind{};
};

// Single producer and single consumer. The socket lifecycle must join the
// old producer before a new socket publishes events. The consumer copies into
// its own scratch before releasing capacity, then fences by generation.
class ReceiveQueue {
public:
    static constexpr uint32_t message_capacity = 8192;
    static constexpr uint64_t timeout_ms = 2000;
    static constexpr uint32_t byte_capacity = 2 * message_capacity;
    static constexpr uint32_t event_capacity = 8;

    // Producer interface. A new socket cancels incomplete assembly before
    // publishing its connection event. Complete events remain in FIFO order.
    bool push_connected(uint32_t generation, uint64_t received_ms);
    FrameResult chunk(uint32_t generation, uint8_t opcode, bool fin, size_t frame_size,
                      size_t offset, std::string_view bytes, uint64_t received_ms);

    // Consumer interface. Scratch must hold the next message, if any.
    bool pop(ReceiveEvent& event, char* scratch, size_t scratch_size);

private:
    bool expired(uint64_t now) const;
    void cancel();
    FrameResult fail(FrameResult result = FrameResult::invalid);
    bool publish(ReceiveKind kind, uint32_t generation, uint64_t received_ms, uint16_t size);

    std::array<char, byte_capacity> bytes_;
    std::array<ReceiveEvent, event_capacity> events_;
    std::atomic<uint32_t> consumed_bytes_{0};
    std::atomic<uint32_t> consumed_events_{0};
    std::atomic<uint32_t> published_events_{0};
    // Producer only. Bytes after the published tail remain invisible until
    // a complete message's event is published, and can be abandoned safely.
    uint64_t started_{};
    uint32_t written_bytes_{}, assembly_generation_{};
    uint16_t pending_bytes_{}, frame_size_{}, frame_received_{};
    uint8_t opcode_{};
    bool message_active_{}, chunk_active_{}, fin_{};
};
} // namespace vault
