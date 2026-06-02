// OEP-1 70/150 | path=include/omnibus/identity/salt.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "../types.hpp"
#include <vector>
#include <string>

namespace omnibus::identity {

class SaltFile {
    std::string path_;
    std::vector<u8> salt_;
    
public:
    explicit SaltFile(const std::string& path = "/var/run/omnibus/salt.bin");
    ~SaltFile();
    
    bool load_or_create();
    std::vector<u8> get() const { return salt_; }
    void regenerate();
    
private:
    void set_permissions() const;
    void create_salt();
};

} // namespace omnibus::identity