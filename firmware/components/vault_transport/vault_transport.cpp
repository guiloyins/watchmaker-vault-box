#include "vault_transport.hpp"
#include <algorithm>
#include <cstring>
namespace vault {
void ReceiveQueue::cancel() {
    pending_bytes_ = frame_size_ = frame_received_ = 0;
    message_active_ = chunk_active_ = false;
}

FrameResult ReceiveQueue::fail(FrameResult result) {
    cancel();
    return result;
}

bool ReceiveQueue::expired(uint64_t now) const {
    return message_active_ && (now < started_ || now - started_ >= timeout_ms);
}

FrameResult ReceiveQueue::chunk(uint32_t generation, uint8_t opcode, bool fin, size_t frame_size,
                                size_t offset, std::string_view bytes, uint64_t now) {
    if (expired(now) || offset > frame_size || bytes.size() > frame_size - offset) return fail();
    if (opcode >= 8) {
        // Driver handles ping/pong protocol replies; they never become JSON or
        // reset the original fragmented-message assembly deadline.
        if (!fin || frame_size > 125 || offset || bytes.size() != frame_size ||
            (opcode != 8 && opcode != 9 && opcode != 10)) return fail();
        if (opcode == 8) return fail(FrameResult::closed);
        return FrameResult::control;
    }
    if (!offset) {
        if (chunk_active_ || (opcode != 0 && opcode != 1)) return fail();
        if (opcode == 1) {
            if (message_active_) return fail();
            started_ = now;
            assembly_generation_ = generation;
            message_active_ = true;
        } else if (!message_active_) return fail();
        if (frame_size > message_capacity - pending_bytes_) return fail();
        opcode_ = opcode; frame_size_ = static_cast<uint16_t>(frame_size); frame_received_ = 0;
        fin_ = fin; chunk_active_ = true;
    }
    if (!chunk_active_ || generation != assembly_generation_ || opcode != opcode_ || fin != fin_ ||
        frame_size != frame_size_ || offset != frame_received_) return fail();

    const auto next_byte = written_bytes_ + pending_bytes_;
    const auto occupied = next_byte - consumed_bytes_.load(std::memory_order_acquire);
    if (bytes.size() > byte_capacity - occupied) return fail(FrameResult::overflow);
    if (!bytes.empty()) {
        const auto ring_offset = next_byte % byte_capacity;
        const auto first = std::min<size_t>(bytes.size(), byte_capacity - ring_offset);
        std::memcpy(bytes_.data() + ring_offset, bytes.data(), first);
        if (first < bytes.size()) std::memcpy(bytes_.data(), bytes.data() + first, bytes.size() - first);
        pending_bytes_ += static_cast<uint16_t>(bytes.size());
        frame_received_ += static_cast<uint16_t>(bytes.size());
    }
    if (frame_received_ != frame_size_) return FrameResult::incomplete;
    chunk_active_ = false;
    if (!fin) return FrameResult::incomplete;

    const auto published = publish(ReceiveKind::text, generation, now, pending_bytes_);
    cancel();
    return published ? FrameResult::message : FrameResult::overflow;
}

bool ReceiveQueue::push_connected(uint32_t generation, uint64_t received_ms) {
    cancel();
    return publish(ReceiveKind::connected, generation, received_ms, 0);
}

bool ReceiveQueue::publish(ReceiveKind kind, uint32_t generation, uint64_t received_ms, uint16_t size) {
    const auto tail = published_events_.load(std::memory_order_relaxed);
    if (tail - consumed_events_.load(std::memory_order_acquire) == event_capacity) return false;
    events_[tail % event_capacity] = {received_ms, generation, size, kind};
    written_bytes_ += size;
    published_events_.store(tail + 1, std::memory_order_release);
    return true;
}

bool ReceiveQueue::pop(ReceiveEvent& event, char* scratch, size_t scratch_size) {
    const auto head = consumed_events_.load(std::memory_order_relaxed);
    if (head == published_events_.load(std::memory_order_acquire)) return false;
    const auto next = events_[head % event_capacity];
    if (next.size > scratch_size || (next.size && !scratch)) return false;

    if (next.size) {
        const auto read = consumed_bytes_.load(std::memory_order_relaxed);
        const auto offset = read % byte_capacity;
        const auto first = std::min<size_t>(next.size, byte_capacity - offset);
        std::memcpy(scratch, bytes_.data() + offset, first);
        if (first < next.size) std::memcpy(scratch + first, bytes_.data(), next.size - first);
        consumed_bytes_.store(read + next.size, std::memory_order_release);
    }
    event = next;
    consumed_events_.store(head + 1, std::memory_order_release);
    return true;
}
} // namespace vault
