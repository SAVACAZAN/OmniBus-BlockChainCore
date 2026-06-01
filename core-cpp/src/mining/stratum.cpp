#include "../../include/omnibus/mining/stratum.hpp"
#include <spdlog/spdlog.h>
#include <boost/algorithm/string.hpp>
#include <sstream>

namespace omnibus::mining {

StratumServer::StratumServer(u16 port, std::shared_ptr<MiningPool> pool)
    : acceptor_(io_, boost::asio::ip::tcp::endpoint(boost::asio::ip::tcp::v4(), port)),
      pool_(pool) {
    spdlog::info("Stratum server listening on port {}", port);
}

StratumServer::~StratumServer() { stop(); }

void StratumServer::start() {
    do_accept();
    std::thread([this]() { io_.run(); }).detach();
}

void StratumServer::stop() {
    io_.stop();
}

void StratumServer::do_accept() {
    auto socket = std::make_shared<boost::asio::ip::tcp::socket>(io_);
    acceptor_.async_accept(*socket, [this, socket](boost::system::error_code ec) {
        if (!ec) {
            handle_client(socket);
        }
        do_accept();
    });
}

void StratumServer::handle_client(std::shared_ptr<boost::asio::ip::tcp::socket> socket) {
    auto session_id = std::to_string(reinterpret_cast<uintptr_t>(socket.get()));
    sessions_[socket] = session_id;
    
    auto buf = std::make_shared<boost::asio::streambuf>();
    boost::asio::async_read_until(*socket, *buf, "\n",
        [this, socket, buf](boost::system::error_code ec, size_t len) {
            if (!ec) {
                std::istream is(buf.get());
                std::string line;
                std::getline(is, line);
                boost::trim(line);
                process_request(line, socket);
                handle_client(socket);
            } else {
                sessions_.erase(socket);
            }
        });
}

void StratumServer::process_request(const std::string& data, std::shared_ptr<boost::asio::ip::tcp::socket> socket) {
    try {
        auto j = json::parse(data);
        std::string method = j["method"];
        auto params = j["params"];
        auto id = j["id"];
        
        json response;
        response["id"] = id;
        
        if (method == "mining.subscribe") {
            response["result"] = handle_mining_subscribe(params);
        } else if (method == "mining.authorize") {
            response["result"] = handle_mining_authorize(params, sessions_[socket]);
        } else if (method == "mining.submit") {
            response["result"] = handle_mining_submit(params, sessions_[socket]);
        } else {
            response["error"] = json::object();
            response["error"]["code"] = -32601;
            response["error"]["message"] = "Method not found";
        }
        
        send_message(socket, response);
    } catch (const std::exception& e) {
        spdlog::error("Stratum parse error: {}", e.what());
    }
}

void StratumServer::send_message(std::shared_ptr<boost::asio::ip::tcp::socket> socket, const json& msg) {
    std::string data = msg.dump() + "\n";
    boost::asio::async_write(*socket, boost::asio::buffer(data),
        [](boost::system::error_code ec, size_t) {
            if (ec) spdlog::error("Stratum send error: {}", ec.message());
        });
}

json StratumServer::handle_mining_subscribe(const json& params) {
    json result = json::array();
    result.push_back(json::array());
    result.push_back(std::to_string(++job_counter_));
    return result;
}

json StratumServer::handle_mining_authorize(const json& params, const std::string& session_id) {
    if (params.size() >= 2) {
        std::string worker = params[0];
        std::string password = params[1];
        spdlog::info("Stratum authorize: worker={}, session={}", worker, session_id);
        return true;
    }
    return false;
}

json StratumServer::handle_mining_submit(const json& params, const std::string& session_id) {
    if (params.size() >= 5) {
        std::string worker = params[0];
        std::string job_id = params[1];
        std::string nonce = params[2];
        std::string hash = params[3];
        spdlog::debug("Stratum submit: worker={}, job={}, nonce={}", worker, job_id, nonce);
        return true;
    }
    return false;
}

void StratumServer::broadcast_new_job(const StratumJob& job) {
    current_job_ = job;
    json notification;
    notification["method"] = "mining.notify";
    notification["params"] = json::array();
    notification["params"].push_back(job.job_id);
    notification["params"].push_back(job.prev_hash.data());
    notification["params"].push_back(job.merkle_root.data());
    notification["params"].push_back(std::to_string(job.timestamp));
    notification["params"].push_back(std::to_string(job.bits));
    notification["params"].push_back(job.clean_jobs);
    
    for (const auto& [socket, id] : sessions_) {
        send_message(socket, notification);
    }
}

} // namespace omnibus::mining