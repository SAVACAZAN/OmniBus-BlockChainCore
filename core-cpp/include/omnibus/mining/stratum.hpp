#pragma once
#include "../types.hpp"
#include <boost/asio.hpp>
#include <nlohmann/json.hpp>
#include <map>
#include <memory>

namespace omnibus::mining {

using json = nlohmann::json;

struct StratumJob {
    std::string job_id;
    Hash256 prev_hash;
    Hash256 merkle_root;
    u32 timestamp;
    u32 bits;
    u32 height;
    bool clean_jobs;
};

class StratumServer {
    boost::asio::io_context io_;
    boost::asio::ip::tcp::acceptor acceptor_;
    std::map<std::shared_ptr<boost::asio::ip::tcp::socket>, std::string> sessions_;
    std::shared_ptr<MiningPool> pool_;
    StratumJob current_job_;
    u64 job_counter_ = 0;
    
public:
    StratumServer(u16 port, std::shared_ptr<MiningPool> pool);
    ~StratumServer();
    
    void start();
    void stop();
    void broadcast_new_job(const StratumJob& job);
    
private:
    void do_accept();
    void handle_client(std::shared_ptr<boost::asio::ip::tcp::socket> socket);
    void send_message(std::shared_ptr<boost::asio::ip::tcp::socket> socket, const json& msg);
    void process_request(const std::string& data, std::shared_ptr<boost::asio::ip::tcp::socket> socket);
    
    // Stratum v1 methods
    json handle_mining_subscribe(const json& params);
    json handle_mining_authorize(const json& params, const std::string& session_id);
    json handle_mining_submit(const json& params, const std::string& session_id);
};

} // namespace omnibus::mining