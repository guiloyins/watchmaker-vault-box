#pragma once
#include "vault_storage.hpp"
#include "nvs.h"
namespace vault::idf {
bool sha256(std::string_view bytes, service::Digest& digest);
class NvsStorage final : public service::Storage {
public:
    bool configure_scratch(char* buffer, size_t size);
    bool open();
    service::Load load(service::ControllerRecord& record) override;
    service::Commit commit(const service::ControllerRecord& record) override;
private:
    nvs_handle_t handle_{};
    bool ready_{};
    char* buffer_{};
    size_t buffer_size_{};
};
}
