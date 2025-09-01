#ifndef _SA_CONF_
#define _SA_CONF_

#include "pchheader.hpp"
#include "util/util.hpp"

namespace conf
{
    // Log severity levels used in Sashimono agent.
    enum LOG_SEVERITY
    {
        DEBUG,
        INFO,
        WARN,
        ERROR
    };

    struct host_ip_port
    {
        std::string host_address;
        uint16_t port = 0;

        bool operator==(const host_ip_port &other) const
        {
            return host_address == other.host_address && port == other.port;
        }

        bool operator!=(const host_ip_port &other) const
        {
            return !(host_address == other.host_address && port == other.port);
        }

        bool operator<(const host_ip_port &other) const
        {
            return (host_address == other.host_address) ? port < other.port : host_address < other.host_address;
        }

        const std::string to_string() const
        {
            return host_address + ":" + std::to_string(port);
        }
    };

    struct ugid
    {
        uid_t uid = 0;
        gid_t gid = 0;

        bool empty() const
        {
            return uid <= 0 && gid <= 0;
        }

        const std::string to_string() const
        {
            return (uid == 0 && gid == 0) ? "" : (std::to_string(uid) + ":" + std::to_string(gid));
        }
    };

    struct log_config
    {
        std::string log_level;                            // Log severity level (dbg, inf, wrn, wrr)
        LOG_SEVERITY log_level_type = LOG_SEVERITY::INFO; // Log severity level enum (debug, info, warn, error)
        std::unordered_set<std::string> loggers;          // List of enabled loggers (console, file)
        size_t max_mbytes_per_file = 0;                   // Max MB size of a single log file.
        size_t max_file_count = 0;                        // Max no. of log files to keep.
    };

    struct hp_config
    {
        std::string host_address;
        uint16_t init_peer_port = 0;
        uint16_t init_user_port = 0;
        uint16_t init_gp_tcp_port = 0;
        uint16_t init_gp_udp_port = 0;
    };

    struct system_config
    {
        size_t max_cpu_us = 0;         // Max CPU time allocated to all instances (out of 1000000 microsec).
        size_t max_mem_kbytes = 0;     // Max memory allocated to all instances in KB.
        size_t max_swap_kbytes = 0;    // Max swap memory allocated to all instances in KB.
        size_t max_storage_kbytes = 0; // Max physical storage  allocated to all instances in KB.
        size_t max_instance_count = 0; // Max number of instances that can be created.
    };

    struct docker_config
    {
        std::string image_prefix;     // Docker image prefixes allowed to be used for contracts.
        uint16_t registry_port = 0;   // 0 means bypass private docker registry.
        std::string registry_address; // This is dynamically constructed at load time.
    };

    struct sa_config
    {
        std::string version;
        hp_config hp;
        system_config system;
        docker_config docker;
        log_config log;
    };

    struct sa_context
    {
        std::string command;                // The CLI command issued to launch Sashimono agent
        std::string exe_dir;                // Sashimono Agent executable dir.
        std::string hpfs_exe_path;          // hpfs executable file path.
        std::string contract_template_path; // Path to default contract.

        std::string socket_path; // Path to the unix socket file.

        std::string user_install_sh;
        std::string user_uninstall_sh;

        std::string config_file; // Full path to the config file.
        std::string log_dir;     // Log directory full path.
        std::string data_dir;    // Data directory full path.
        std::string dns_evernode_sh;
    };

    // Global context struct exposed to the application.
    // Other modules will access context values via this.
    extern sa_context ctx;

    // Global configuration struct exposed to the application.
    // Other modules will access config values via this.
    extern sa_config cfg;

    int init();

    int create(std::string_view host_addr, const uint16_t init_peer_port, const uint16_t init_user_port,const uint16_t init_gp_tcp_port, const uint16_t init_gp_udp_port, const uint16_t docker_registry_port,
               const size_t inst_count, const size_t cpu_us, const size_t ram_kbytes, const size_t swap_kbytes, const size_t disk_kbytes);

    void set_dir_paths(std::string exepath, std::string datadir);

    int validate_dir_paths();

    int read_config(sa_config &cfg);

    int write_config(const sa_config &cfg);

    int write_json_file(const std::string &file_path, const jsoncons::ojson &d);

    LOG_SEVERITY get_loglevel_type(std::string_view severity);

    void print_missing_field_error(std::string_view jpath, const std::exception &e);

    int validate_config(const sa_config &cfg);

}

#endif