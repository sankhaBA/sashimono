#ifndef _SA_HP_MANAGER_
#define _SA_HP_MANAGER_

#include "pchheader.hpp"
#include "hpfs_manager.hpp"
#include "conf.hpp"
#include "conf.hpp"
#include "msg/msg_common.hpp"

namespace hp
{
    constexpr const char *CONTAINER_STATES[]{"created", "running", "stopped", "destroyed", "exited"};

    enum STATES
    {
        CREATED,
        RUNNING,
        STOPPED,
        DESTROYED,
        EXITED
    };

    // Stores ports assigned to a container.
    struct ports
    {
        uint16_t peer_port = 0;
        uint16_t user_port = 0;

        uint16_t gp_tcp_port_start = 0;
        uint16_t gp_udp_port_start = 0;

        bool operator==(const ports &other) const
        {
            return peer_port == other.peer_port && user_port == other.user_port && gp_tcp_port_start == other.gp_tcp_port_start && gp_udp_port_start == other.gp_udp_port_start;
        }
    };

    struct instance_info
    {
        std::string owner_pubkey;
        std::string container_name;
        std::string contract_dir;
        std::string ip;
        std::string pubkey;
        std::string contract_id;
        ports assigned_ports;
        std::string status;
        std::string username;
        std::string image_name;
    };

    // Represents a lease data retured from message board database.
    struct lease_info
    {
        uint64_t timestamp;
        std::string container_name;
        std::string tenant_xrp_address;
        uint64_t created_on_ledger;
        uint64_t life_moments;
    };

    struct resources
    {
        size_t cpu_us = 0;         // CPU time an instance can consume.
        size_t mem_kbytes = 0;     // Memory an instance can allocate.
        size_t swap_kbytes = 0;    // Swap memory an instance can allocate.
        size_t storage_kbytes = 0; // Physical storage an instance can allocate.
    };

    int init();

    void deinit();

    int create_new_instance(std::string &error_msg, instance_info &info, std::string_view container_name, std::string_view owner_pubkey, const std::string &contract_id, const std::string &image_key, std::string_view outbound_ipv6, std::string_view outbound_net_interface);

    int initiate_instance(std::string &error_msg, std::string_view container_name, const msg::initiate_msg &config_msg);

    int create_container(std::string_view username, std::string_view image_name, std::string_view container_name, std::string_view contract_dir, const ports &assigned_ports, instance_info &info);

    int start_container(std::string_view container_name);

    int docker_start(std::string_view username, std::string_view container_name);

    int docker_stop(std::string_view username, std::string_view container_name);

    int docker_remove(std::string_view username, std::string_view container_name);

    int stop_container(std::string_view container_name);

    int destroy_container(std::string &error_msg, std::string_view container_name);

    int create_contract(std::string_view username, std::string_view owner_pubkey, std::string_view contract_id,
                        std::string_view contract_dir, const ports &assigned_ports, instance_info &info);

    int check_instance_status(std::string_view username, std::string_view container_name, std::string &status);

    int read_json_values(const jsoncons::ojson &d, std::string &hpfs_log_level, bool &is_full_history);

    int write_json_values(jsoncons::ojson &d, const msg::config_struct &config);

    int install_user(int &user_id, std::string &username, const size_t max_cpu_us, const size_t max_mem_kbytes, const size_t max_swap_kbytes,
                     const size_t storage_kbytes, std::string_view container_name, const ports instance_ports, std::string_view docker_image,
                     std::string_view outbound_ipv6, std::string_view outbound_net_interface);

    int uninstall_user(std::string_view username, const ports assigned_ports, std::string_view instance_name);

    void get_instance_list(std::vector<hp::instance_info> &instances);

    void get_lease_list(std::vector<hp::lease_info> &leases);

    int get_instance(std::string &error_msg, std::string_view container_name, hp::instance_info &instance);

    bool is_cgroup_v2();

    bool cgroup_v2_ready();

    bool cgroup_v1_ready();

    bool system_ready();

    void get_vacant_ports_list(std::vector<hp::ports> &vacant_ports);

} // namespace hp
#endif