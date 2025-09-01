#include "hp_manager.hpp"
#include "crypto.hpp"
#include "util/util.hpp"
#include "sqlite.hpp"

namespace hp
{
    // Keep track of the ports of the most recent hp instance.
    ports last_assigned_ports;

    resources instance_resources;

    // This is defaults to true because it initialize last assigned ports when a new instance is created if there is no vacant ports available.
    bool last_port_assign_from_vacant = true;

    constexpr int FILE_PERMS = 0644;
    constexpr int DOCKER_CREATE_TIMEOUT_SECS = 120; // Max timeout for docker create command to execute.

    sqlite3 *db = NULL;    // Database connection for hp related sqlite stuff.
    sqlite3 *db_mb = NULL; // Database connection for messageboard related sqlite stuff.

    // Vector keeping vacant ports from destroyed instances.
    std::vector<ports> vacant_ports;

    bool is_shutting_down = false;

    conf::ugid contract_ugid;
    constexpr int CONTRACT_USER_ID = 10000;
    constexpr int CONTRACT_GROUP_ID = 0;

    // We instruct the demon to restart the container automatically once the container exits except manually stopping.
    // We keep docker logs at size limit of 10mb, We only need these logs for docker instance failure debugging since all other logs are kept in files.
    // For the local log driver compression, minimum max-file should be 2. So we keep two logs each max-size is 5mb
    constexpr const char *DOCKER_CREATE = "DOCKER_HOST=unix:///run/user/$(id -u %s)/docker.sock timeout --foreground -v -s SIGINT %ss %s/dockerbin/docker create -t -i --stop-signal=SIGINT --log-driver local \
     --log-opt max-size=5m --log-opt max-file=2 --name=%s -p %s:%s -p %s:%s -p %s:%s/udp -p %s:%s -p %s:%s -p %s:%s/udp -p %s:%s/udp --restart unless-stopped --mount type=bind,source=%s,target=/contract %s run /contract";
    constexpr const char *DOCKER_START = "DOCKER_HOST=unix:///run/user/$(id -u %s)/docker.sock %s/dockerbin/docker start %s";
    constexpr const char *DOCKER_STOP = "DOCKER_HOST=unix:///run/user/$(id -u %s)/docker.sock %s/dockerbin/docker stop %s";
    constexpr const char *DOCKER_REMOVE = "DOCKER_HOST=unix:///run/user/$(id -u %s)/docker.sock %s/dockerbin/docker rm -f %s";
    constexpr const char *DOCKER_STATUS = "DOCKER_HOST=unix:///run/user/$(id -u %s)/docker.sock %s/dockerbin/docker inspect --format='{{json .State.Status}}' %s";
    constexpr const char *COPY_DIR = "cp -r %s %s";
    constexpr const char *MOVE_DIR = "mv %s %s";
    constexpr const char *CHOWN_DIR = "chown -R %s:%s %s";
    constexpr const char *CHMOD_DIR = "chmod -R %s %s";

    // Error codes used in create and initiate instance.
    constexpr const char *DB_READ_ERROR = "db_read_error";
    constexpr const char *DB_WRITE_ERROR = "db_write_error";
    constexpr const char *USER_INSTALL_ERROR = "user_install_error";
    constexpr const char *USER_UNINSTALL_ERROR = "user_uninstall_error";
    constexpr const char *INSTANCE_ERROR = "instance_error";
    constexpr const char *CONF_READ_ERROR = "conf_read_error";
    constexpr const char *CONTAINER_CONF_ERROR = "container_conf_error";
    constexpr const char *CONTAINER_START_ERROR = "container_start_error";
    constexpr const char *CONTAINER_UPDATE_ERROR = "container_update_error";
    constexpr const char *CONTAINER_DESTROY_ERROR = "container_destroy_error";
    constexpr const char *NO_CONTAINER = "no_container";
    constexpr const char *DUP_CONTAINER = "dup_container";
    constexpr const char *MAX_ALLOCATION_REACHED = "max_alloc_reached";
    constexpr const char *CONTRACT_ID_INVALID = "contractid_bad_format";
    constexpr const char *DOCKER_IMAGE_INVALID = "docker_image_invalid";
    constexpr const char *DOCKER_CONTAINER_NOT_FOUND = "container_not_found";
    constexpr const char *INSTANCE_ALREADY_EXISTS = "instance_already_exists";

    // Cgrules check related constants.
    constexpr const char *CGRULE_ACTIVE = "service=$(grep \"ExecStart.*=.*/cgrulesengd$\" /etc/systemd/system/*.service | head -1 | awk -F : ' { print $1 } ') && [ ! -z $service ] && systemctl is-active $(basename $service)";
    constexpr const char *CGRULE_CPU_DIR = "/sys/fs/cgroup/cpu";
    constexpr const char *CGRULE_MEM_DIR = "/sys/fs/cgroup/memory";
    constexpr const char *CGRULE_CONF = "/etc/cgrules.conf";
    constexpr const char *CGRULE_REGEXP = "(^|\n)(\\s*)@sashiuser(\\s+)cpu,memory(\\s+)\%u-cg(\\s*)($|\n)";
    constexpr const char *REBOOT_FILE = "/run/reboot-required.pkgs";
    constexpr const char *REBOOT_REGEXP = "(^|\n)(\\s*)sashimono(\\s*)($|\n)";

    /**
     * Initialize hp related environment.
     */
    int init()
    {
        // First, check whether system is ready to start.
        if (!system_ready())
            return -1;

        const std::string db_path = conf::ctx.data_dir + "/sa.sqlite";
        if (sqlite::open_db(db_path, &db, true) == -1 ||
            sqlite::initialize_hp_db(db) == -1)
        {
            LOG_ERROR << "Error preparing database in " << db_path;
            return -1;
        }

        // Populate the vacant ports vector with vacant ports of destroyed containers.
        get_vacant_ports_list(vacant_ports);
        // Calculate the resources per instance.
        instance_resources.cpu_us = conf::cfg.system.max_cpu_us / conf::cfg.system.max_instance_count;
        instance_resources.mem_kbytes = conf::cfg.system.max_mem_kbytes / conf::cfg.system.max_instance_count;
        instance_resources.swap_kbytes = instance_resources.mem_kbytes + (conf::cfg.system.max_swap_kbytes / conf::cfg.system.max_instance_count);
        instance_resources.storage_kbytes = conf::cfg.system.max_storage_kbytes / conf::cfg.system.max_instance_count;
        // Set run as group id 0 (sashimono user group id, root user inside docker container).
        // Because contract user is in sashimono user's group, so the contract user will get the group permissions.
        contract_ugid = {CONTRACT_USER_ID, CONTRACT_GROUP_ID};

        return 0;
    }

    /**
     * Do hp related cleanups.
     */
    void deinit()
    {
        is_shutting_down = true;

        if (db != NULL)
            sqlite::close_db(&db);
    }

    /**
     * Create a new instance of hotpocket. A new contract is created with docker image.
     * @param error_msg Error message if any.
     * @param info Structure holding the generated instance info.
     * @param owner_pubkey Public key of the instance owner.
     * @param contract_id Contract id to be configured.
     * @param image Docker image name to use (image prefix name must exists).
     * @return 0 on success and -1 on error.
     */
    int create_new_instance(std::string &error_msg, instance_info &info, std::string_view container_name, std::string_view owner_pubkey, const std::string &contract_id, const std::string &image, std::string_view outbound_ipv6, std::string_view outbound_net_interface)
    {
        // Creating an instance with same name is not allowed.
        hp::instance_info existing_instance;
        if (sqlite::get_instance(db, container_name, existing_instance) == 0)
        {
            error_msg = INSTANCE_ALREADY_EXISTS;
            LOG_ERROR << "Found another instance with name: " << container_name << ".";
            return -1;
        }

        // If the max allowed instance count is already allocated. We won't allow more.
        const int allocated_count = sqlite::get_allocated_instance_count(db);
        if (allocated_count == -1)
        {
            error_msg = DB_READ_ERROR;
            LOG_ERROR << "Error getting allocated instance count from db.";
            return -1;
        }
        else if ((size_t)allocated_count >= conf::cfg.system.max_instance_count)
        {
            error_msg = MAX_ALLOCATION_REACHED;
            LOG_ERROR << "Max instance count is reached.";
            return -1;
        }

        LOG_INFO << "Resources for instance - CPU: " << instance_resources.cpu_us << " MicroS, RAM: " << instance_resources.mem_kbytes << " KB, Storage: " << instance_resources.storage_kbytes << " KB.";

        // First check whether contract_id is valid uuid.
        if (!crypto::verify_uuid(contract_id))
        {
            error_msg = CONTRACT_ID_INVALID;
            LOG_ERROR << "Provided contract id is not a valid uuid.";
            return -1;
        }

        // Allow any image outside of Evernode labs
        // if (image.substr(0, conf::cfg.docker.image_prefix.size()) != conf::cfg.docker.image_prefix)
        // {
        //     error_msg = DOCKER_IMAGE_INVALID;
        //     LOG_ERROR << "Provided docker image is not allowed.";
        //     return -1;
        // }

        std::string image_name = image;

        ports instance_ports;
        if (!vacant_ports.empty())
        {
            // Assign a port pair from one of destroyed instances.
            instance_ports = vacant_ports.back();
            last_port_assign_from_vacant = true;
        }
        else
        {
            if (last_port_assign_from_vacant)
            {
                sqlite::get_max_ports(db, last_assigned_ports);
                last_port_assign_from_vacant = false;
            }
            instance_ports = {(uint16_t)(last_assigned_ports.peer_port + 1), (uint16_t)(last_assigned_ports.user_port + 1), (uint16_t)(last_assigned_ports.gp_tcp_port_start + 2), (uint16_t)(last_assigned_ports.gp_udp_port_start + 2)};
        }

        int user_id;
        std::string username;
        if (install_user(
                user_id, username, instance_resources.cpu_us, instance_resources.mem_kbytes, instance_resources.swap_kbytes,
                instance_resources.storage_kbytes, container_name, instance_ports, image_name, outbound_ipv6, outbound_net_interface) == -1)
        {
            error_msg = USER_INSTALL_ERROR;
            return -1;
        }

        const std::string contract_dir = util::get_user_contract_dir(username, container_name);

        auto pos = image_name.find("--");
        if (pos != std::string::npos) {
            image_name = image_name.substr(0, pos);
        }

        if (create_contract(username, owner_pubkey, contract_id, contract_dir, instance_ports, info) == -1 ||
            create_container(username, image_name, container_name, contract_dir, instance_ports, info) == -1)
        {
            error_msg = INSTANCE_ERROR;
            LOG_ERROR << "Error creating hp instance for " << owner_pubkey;
            // Remove user if instance creation failed.
            uninstall_user(username, instance_ports, container_name);
            return -1;
        }

        if (sqlite::insert_hp_instance_row(db, info) == -1)
        {
            error_msg = DB_WRITE_ERROR;
            LOG_ERROR << "Error inserting instance data into db for " << owner_pubkey;
            // Remove container and uninstall user if database update failed.
            docker_remove(username, container_name);
            uninstall_user(username, instance_ports, container_name);
            return -1;
        }

        if (last_port_assign_from_vacant)
            vacant_ports.pop_back();
        else
            last_assigned_ports = instance_ports;

        return 0;
    }

    /**
     * Initiate the instance. The config will be updated and container will be started.
     * @param error_msg Error message if any.
     * @param container_name Name of the container.
     * @param config_msg Config values for the hp instance.
     * @return 0 on success and -1 on error.
     */
    int initiate_instance(std::string &error_msg, std::string_view container_name, const msg::initiate_msg &config_msg)
    {
        instance_info info;
        const int res = sqlite::is_container_exists(db, container_name, info);
        if (res == 0)
        {
            error_msg = NO_CONTAINER;
            LOG_ERROR << "Given container not found. name: " << container_name;
            return -1;
        }
        else if (info.status != CONTAINER_STATES[STATES::CREATED])
        {
            error_msg = DUP_CONTAINER;
            LOG_ERROR << "Given container is already initiated. name: " << container_name;
            return -1;
        }

        // Read the config file into json document object.
        const std::string contract_dir = util::get_user_contract_dir(info.username, container_name);
        std::string config_file_path(contract_dir);
        config_file_path.append("/cfg/hp.cfg");
        const int config_fd = open(config_file_path.data(), O_RDWR, FILE_PERMS);
        if (config_fd == -1)
        {
            error_msg = CONF_READ_ERROR;
            LOG_ERROR << errno << ": Error opening config file " << config_file_path;
            return -1;
        }

        jsoncons::ojson d;
        std::string hpfs_log_level;
        bool is_full_history;
        if (util::read_json_file(config_fd, d) == -1 ||
            write_json_values(d, config_msg.config) == -1 ||
            read_json_values(d, hpfs_log_level, is_full_history) == -1 ||
            util::write_json_file(config_fd, d) == -1 ||
            hpfs::update_service_conf(info.username, hpfs_log_level, is_full_history) == -1 ||
            hpfs::start_hpfs_systemd(info.username) == -1)
        {
            error_msg = CONTAINER_CONF_ERROR;
            LOG_ERROR << "Error when setting up container. name: " << container_name;
            close(config_fd);
            return -1;
        }
        close(config_fd);

        if (docker_start(info.username, container_name) == -1)
        {
            error_msg = CONTAINER_START_ERROR;
            LOG_ERROR << "Error when starting container. name: " << container_name;
            // Stop started hpfs processes if starting instance failed.
            hpfs::stop_hpfs_systemd(info.username);
            return -1;
        }

        if (sqlite::update_status_in_container(db, container_name, CONTAINER_STATES[STATES::RUNNING]) == -1)
        {
            error_msg = CONTAINER_UPDATE_ERROR;
            LOG_ERROR << "Error when updating container status. name: " << container_name;
            // Stop started docker and hpfs processes if database update fails.
            docker_stop(info.username, container_name);
            hpfs::stop_hpfs_systemd(info.username);
            return -1;
        }

        return 0;
    }

    /**
     * Creates a hotpocket docker image on the given contract and the ports.
     * @param username Username of the instance user.
     * @param image_name Conatiner image name to use.
     * @param container_name Name of the container.
     * @param contract_dir Directory for the contract.
     * @param assigned_ports Assigned ports to the container.
     * @return 0 on success execution or relavent error code on error.
     */
    int create_container(std::string_view username, std::string_view image_name, std::string_view container_name, std::string_view contract_dir, const ports &assigned_ports, instance_info &info)
    {
        const std::string user_port = std::to_string(assigned_ports.user_port);
        const std::string peer_port = std::to_string(assigned_ports.peer_port);
        const std::string gp_tcp_port_1 = std::to_string(assigned_ports.gp_tcp_port_start);
        const std::string gp_tcp_port_2 = std::to_string(assigned_ports.gp_tcp_port_start + 1);
        const std::string gp_udp_port_1 = std::to_string(assigned_ports.gp_udp_port_start);
        const std::string gp_udp_port_2 = std::to_string(assigned_ports.gp_udp_port_start + 1);
        const std::string timeout = std::to_string(DOCKER_CREATE_TIMEOUT_SECS);
        const int len = 376 + username.length() + timeout.length() + conf::ctx.exe_dir.length() + container_name.length() + (user_port.length() * 2) + (peer_port.length() * 4) + (gp_tcp_port_1.length() * 2) + (gp_tcp_port_2.length() * 2) + (gp_udp_port_1.length() * 2) + (gp_udp_port_2.length() * 2) + contract_dir.length() + image_name.length();
        char command[len];
        sprintf(command, DOCKER_CREATE, username.data(), timeout.data(), conf::ctx.exe_dir.data(), container_name.data(),
                user_port.data(), user_port.data(),
                peer_port.data(), peer_port.data(),
                peer_port.data(), peer_port.data(),
                gp_tcp_port_1.data(), gp_tcp_port_1.data(),
                gp_tcp_port_2.data(), gp_tcp_port_2.data(),
                gp_udp_port_1.data(), gp_udp_port_1.data(),
                gp_udp_port_2.data(), gp_udp_port_2.data(),
                contract_dir.data(), image_name.data());

        LOG_INFO << "Creating the docker container. name: " << container_name;
        if (system(command) != 0)
        {
            LOG_ERROR << "Error when running container. name: " << container_name;
            return -1;
        }

        info.container_name = container_name;
        info.contract_dir = contract_dir;
        info.image_name = image_name;
        return 0;
    }

    /**
     * Stops the container with given name if exists.
     * @param container_name Name of the container.
     * @return 0 on success execution or relavent error code on error.
     */
    int stop_container(std::string_view container_name)
    {
        instance_info info;
        const int res = sqlite::is_container_exists(db, container_name, info);
        if (res == 0)
        {
            LOG_ERROR << "Given container not found. name: " << container_name;
            return -1;
        }
        else if (info.status != CONTAINER_STATES[STATES::RUNNING])
        {
            LOG_ERROR << "Given container is not running. name: " << container_name;
            return -1;
        }

        if (docker_stop(info.username, container_name) == -1 ||
            sqlite::update_status_in_container(db, container_name, CONTAINER_STATES[STATES::STOPPED]) == -1 ||
            hpfs::stop_hpfs_systemd(info.username) == -1)
        {
            LOG_ERROR << "Error when stopping container. name: " << container_name;
            return -1;
        }

        return 0;
    }

    /**
     * Starts the container with given name if exists.
     * @param container_name Name of the container.
     * @return 0 on success execution or relavent error code on error.
     */
    int start_container(std::string_view container_name)
    {
        instance_info info;
        const int res = sqlite::is_container_exists(db, container_name, info);
        if (res == 0)
        {
            LOG_ERROR << "Given container not found. name: " << container_name;
            return -1;
        }
        else if (info.status != CONTAINER_STATES[STATES::STOPPED])
        {
            LOG_ERROR << "Given container is not stopped. name: " << container_name;
            return -1;
        }
        // Read the config file into json document object.
        const std::string contract_dir = util::get_user_contract_dir(info.username, container_name);
        std::string config_file_path(contract_dir);
        config_file_path.append("/cfg/hp.cfg");
        const int config_fd = open(config_file_path.data(), O_RDONLY, FILE_PERMS);
        if (config_fd == -1)
        {
            LOG_ERROR << errno << ": Error opening hp config file " << config_file_path;
            return -1;
        }

        jsoncons::ojson d;
        std::string hpfs_log_level;
        bool is_full_history;
        if (util::read_json_file(config_fd, d) == -1 ||
            read_json_values(d, hpfs_log_level, is_full_history) == -1 ||
            hpfs::update_service_conf(info.username, hpfs_log_level, is_full_history) == -1 ||
            hpfs::start_hpfs_systemd(info.username) == -1 ||
            docker_start(info.username, container_name) == -1)
        {
            LOG_ERROR << "Error when starting container. name: " << container_name;
            close(config_fd);
            return -1;
        }
        close(config_fd);

        if (sqlite::update_status_in_container(db, container_name, CONTAINER_STATES[STATES::RUNNING]) == -1)
        {
            LOG_ERROR << "Error when starting container. name: " << container_name;
            // Stop started docker and hpfs processes if database update fails.
            docker_stop(info.username, container_name);
            hpfs::stop_hpfs_systemd(info.username);
            return -1;
        }

        return 0;
    }

    /**
     * Execute docker start <container_name> command.
     * @param username Username of the instance user.
     * @param container_name Name of the container.
     * @return 0 on successful execution and -1 on error.
     */
    int docker_start(std::string_view username, std::string_view container_name)
    {
        const int len = 100 + username.length() + conf::ctx.exe_dir.length() + container_name.length();
        char command[len];
        sprintf(command, DOCKER_START, username.data(), conf::ctx.exe_dir.data(), container_name.data());
        return system(command) == 0 ? 0 : -1;
    }

    /**
     * Execute docker stop <container_name> command.
     * @param username Username of the instance user.
     * @param container_name Name of the container.
     * @return 0 on successful execution and -1 on error.
     */
    int docker_stop(std::string_view username, std::string_view container_name)
    {
        const int len = 99 + username.length() + conf::ctx.exe_dir.length() + container_name.length();
        char command[len];
        sprintf(command, DOCKER_STOP, username.data(), conf::ctx.exe_dir.data(), container_name.data());
        return system(command) == 0 ? 0 : -1;
    }

    /**
     * Execute docker rm <container_name> command.
     * @param username Username of the instance user.
     * @param container_name Name of the container.
     * @return 0 on successful execution and -1 on error.
     */
    int docker_remove(std::string_view username, std::string_view container_name)
    {
        const int len = 100 + username.length() + conf::ctx.exe_dir.length() + container_name.length();
        char command[len];
        sprintf(command, DOCKER_REMOVE, username.data(), conf::ctx.exe_dir.data(), container_name.data());
        return system(command) == 0 ? 0 : -1;
    }

    /**
     * Destroy the container with given name if exists.
     * @param error_msg Error message if any.
     * @param container_name Name of the container.
     * @return 0 on success execution or relavent error code on error.
     */
    int destroy_container(std::string &error_msg, std::string_view container_name)
    {
        instance_info info;
        const int res = sqlite::is_container_exists(db, container_name, info);
        if (res == 0)
        {
            error_msg = NO_CONTAINER;
            LOG_ERROR << "Given container not found. name: " << container_name;
            return -1;
        }

        LOG_INFO << "Deleting instance " << container_name;
        if (uninstall_user(info.username, info.assigned_ports, container_name) == -1 ||
            // sqlite::update_status_in_container(db, container_name, CONTAINER_STATES[STATES::DESTROYED]) == -1) // Soft Deletion.
            sqlite::delete_hp_instance(db, container_name) == -1) // Permanent Deletion.
        {
            error_msg = USER_UNINSTALL_ERROR;
            return -1;
        }
        // Add the port pair of the destroyed container to the vacant port vector.
        if (std::find(vacant_ports.begin(), vacant_ports.end(), info.assigned_ports) == vacant_ports.end())
        {
            if (info.assigned_ports.gp_tcp_port_start == 0)
            {
                const uint16_t increment = ((info.assigned_ports.peer_port - conf::cfg.hp.init_peer_port) * 2);
                const uint16_t gp_tcp_port_start = conf::cfg.hp.init_gp_tcp_port + increment;
                const uint16_t gp_udp_port_start = conf::cfg.hp.init_gp_udp_port + increment;
                vacant_ports.push_back({info.assigned_ports.user_port, info.assigned_ports.peer_port, gp_tcp_port_start, gp_udp_port_start});
            }
            else
            {
                vacant_ports.push_back(info.assigned_ports);
            }
        }

        return 0;
    }

    /**
     * Creates a copy of default contract with the given name and the ports in the instance folder given in the config file.
     * @param username Name of the instance user.
     * @param owner_pubkey Public key of the owner of the instance.
     * @param contract_id Contract id to be configured.
     * @param contract_dir Directory of the contract.
     * @param assigned_ports Assigned ports to the instance.
     * @param info Information of the created contract instance.
     * @return -1 on error and 0 on success.
     *
     */
    int create_contract(std::string_view username, std::string_view owner_pubkey, std::string_view contract_id,
                        std::string_view contract_dir, const ports &assigned_ports, instance_info &info)
    {
        // Creating a temporary directory to do the config manipulations before moved to the contract dir.
        // Folders inside /tmp directory will be cleaned after a reboot. So this will self cleanup folders
        // that might be remaining due to another error in the workflow.
        char templ[17] = "/tmp/sashiXXXXXX";
        const char *temp_dirpath = mkdtemp(templ);
        if (temp_dirpath == NULL)
        {
            LOG_ERROR << errno << ": Error creating temporary directory to create contract folder.";
            return -1;
        }
        const std::string source_path = conf::ctx.contract_template_path + "/*";
        int len = 25 + source_path.length();
        char cp_command[len];
        sprintf(cp_command, COPY_DIR, source_path.data(), temp_dirpath);
        if (system(cp_command) != 0)
        {
            LOG_ERROR << errno << ": Default contract copying failed to " << temp_dirpath;
            return -1;
        }

        const std::string config_dir = std::string(temp_dirpath) + "/cfg";

        // Read the config file into json document object.
        const std::string config_file_path = config_dir + "/hp.cfg";
        const int config_fd = open(config_file_path.data(), O_RDWR, FILE_PERMS);

        if (config_fd == -1)
        {
            LOG_ERROR << errno << ": Error opening hp config file " << config_file_path;
            return -1;
        }

        jsoncons::ojson d;
        if (util::read_json_file(config_fd, d) == -1)
        {
            close(config_fd);
            return -1;
        }

        std::string pubkey, seckey;
        crypto::generate_signing_keys(pubkey, seckey);

        const std::string pubkey_hex = util::to_hex(pubkey);

        d["node"]["public_key"] = pubkey_hex;
        d["node"]["private_key"] = util::to_hex(seckey);
        d["contract"]["id"] = contract_id;
        d["contract"]["run_as"] = contract_ugid.to_string();
        jsoncons::ojson unl(jsoncons::json_array_arg);
        unl.push_back(util::to_hex(pubkey));
        d["contract"]["unl"] = unl;
        d["contract"]["bin_path"] = "bootstrap_contract";
        d["contract"]["bin_args"] = owner_pubkey;
        d["mesh"]["port"] = assigned_ports.peer_port;
        d["user"]["port"] = assigned_ports.user_port;
        d["hpfs"]["external"] = true;

        if (util::write_json_file(config_fd, d) == -1)
        {
            LOG_ERROR << "Writing modified hp config failed.";
            close(config_fd);
            return -1;
        }
        close(config_fd);

        // Move the contract to contract dir
        len = 22 + contract_dir.length();
        char mv_command[len];
        sprintf(mv_command, MOVE_DIR, temp_dirpath, contract_dir.data());
        if (system(mv_command) != 0)
        {
            LOG_ERROR << "Default contract moving failed to " << contract_dir;
            return -1;
        }

        // Transfer ownership to the instance user.
        len = 12 + (username.length() * 2) + contract_dir.length();
        char own_command[len];
        sprintf(own_command, CHOWN_DIR, username.data(), username.data(), contract_dir.data());
        len = 11 + 4 + contract_dir.length();
        // Give group write access to the contract directory, So contract user can write into it.
        char perm_command[len];
        sprintf(perm_command, CHMOD_DIR, "0775", contract_dir.data());
        if (system(own_command) != 0 || system(perm_command) != 0)
        {
            LOG_ERROR << "Changing contract ownership and permissions failed " << contract_dir;
            return -1;
        }

        info.owner_pubkey = owner_pubkey;
        info.username = username;
        info.contract_dir = contract_dir;
        info.ip = conf::cfg.hp.host_address;
        info.contract_id = contract_id;
        info.pubkey = pubkey_hex;
        info.assigned_ports = assigned_ports;
        info.status = CONTAINER_STATES[STATES::CREATED];
        return 0;
    }

    /**
     * Check the status of the given container using docker inspect command.
     * @param username Username of the instance user.
     * @param container_name Name of the container.
     * @param status The variable that holds the status of the container.
     * @return 0 on success and -1 on error.
     */
    int check_instance_status(std::string_view username, std::string_view container_name, std::string &status)
    {
        const int len = 136 + username.length() + conf::ctx.exe_dir.length() + container_name.length();
        char command[len];
        sprintf(command, DOCKER_STATUS, username.data(), conf::ctx.exe_dir.data(), container_name.data());

        char buffer[20];

        if (util::execute_bash_cmd(command, buffer, 20) == -1)
            return -1;

        status = buffer;
        status = status.substr(1, status.length() - 3);

        return 0;
    }

    /**
     * Read only required contract config values
     * @param d Json file to be read.
     * @param hpfs_log_level Hpfs log level.
     * @param is_full_history Contract history mode.
     * @return 0 on success. -1 on failure.
     */
    int read_json_values(const jsoncons::ojson &d, std::string &hpfs_log_level, bool &is_full_history)
    {
        try
        {
            hpfs_log_level = d["hpfs"]["log"]["log_level"].as<std::string>();
        }
        catch (const std::exception &e)
        {
            LOG_ERROR << "Invalid contract config hpfs log. " << e.what();
            return -1;
        }

        const std::unordered_set<std::string> valid_loglevels({"dbg", "inf", "wrn", "err"});
        if (valid_loglevels.count(hpfs_log_level) != 1)
        {
            LOG_ERROR << "Invalid hpfs loglevel configured. Valid values: dbg|inf|wrn|err";
            return -1;
        }

        try
        {
            if (d["node"]["history"] == "full")
                is_full_history = true;
            else if (d["node"]["history"] == "custom")
                is_full_history = false;
            else
            {
                LOG_ERROR << "Invalid history mode. 'full' or 'custom' expected.";
                return -1;
            }
        }
        catch (const std::exception &e)
        {
            LOG_ERROR << "Invalid contract config history mode. " << e.what();
            return -1;
        }

        return 0;
    }

    /**
     * Write contract config values (only updated if provided config values are not empty) into the json file.
     * @param d Json file to be populated.
     * @param config Config values to be updated.
     * @return 0 on success. -1 on failure.
     */
    int write_json_values(jsoncons::ojson &d, const msg::config_struct &config)
    {
        // Contract
        {
            if (!config.contract.unl.empty())
            {
                jsoncons::ojson unl(jsoncons::json_array_arg);
                for (auto &pubkey : config.contract.unl)
                    unl.push_back(util::to_hex(pubkey));
                d["contract"]["unl"] = unl;
            }

            if (config.contract.execute.has_value())
                d["contract"]["execute"] = config.contract.execute.value();

            if (!config.contract.environment.empty())
                d["contract"]["environment"] = config.contract.environment;

            if (config.contract.max_input_ledger_offset.has_value())
                d["contract"]["max_input_ledger_offset"] = config.contract.max_input_ledger_offset.value();

            if (config.contract.consensus.mode.has_value())
                d["contract"]["consensus"]["mode"] = config.contract.consensus.mode.value();

            if (config.contract.consensus.roundtime.has_value())
                d["contract"]["consensus"]["roundtime"] = config.contract.consensus.roundtime.value();

            if (config.contract.consensus.stage_slice.has_value())
                d["contract"]["consensus"]["stage_slice"] = config.contract.consensus.stage_slice.value();

            if (config.contract.consensus.threshold.has_value())
                d["contract"]["consensus"]["threshold"] = config.contract.consensus.threshold.value();

            if (config.contract.npl.mode.has_value())
                d["contract"]["npl"]["mode"] = config.contract.npl.mode.value();

            if (config.contract.round_limits.user_input_bytes.has_value())
                d["contract"]["round_limits"]["user_input_bytes"] = config.contract.round_limits.user_input_bytes.value();

            if (config.contract.round_limits.user_output_bytes.has_value())
                d["contract"]["round_limits"]["user_output_bytes"] = config.contract.round_limits.user_output_bytes.value();

            if (config.contract.round_limits.npl_output_bytes.has_value())
                d["contract"]["round_limits"]["npl_output_bytes"] = config.contract.round_limits.npl_output_bytes.value();

            if (config.contract.round_limits.proc_cpu_seconds.has_value())
                d["contract"]["round_limits"]["proc_cpu_seconds"] = config.contract.round_limits.proc_cpu_seconds.value();

            if (config.contract.round_limits.proc_mem_bytes.has_value())
                d["contract"]["round_limits"]["proc_mem_bytes"] = config.contract.round_limits.proc_mem_bytes.value();

            if (config.contract.round_limits.proc_ofd_count.has_value())
                d["contract"]["round_limits"]["proc_ofd_count"] = config.contract.round_limits.proc_ofd_count.value();

            if (config.contract.round_limits.exec_timeout.has_value())
                d["contract"]["round_limits"]["exec_timeout"] = config.contract.round_limits.exec_timeout.value();

            if (config.contract.log.max_mbytes_per_file.has_value())
                d["contract"]["log"]["max_mbytes_per_file"] = config.contract.log.max_mbytes_per_file.value();

            if (config.contract.log.max_file_count.has_value())
                d["contract"]["log"]["max_file_count"] = config.contract.log.max_file_count.value();
        }

        // Node
        {
            if (!config.node.role.empty())
            {
                if (config.node.role != "observer" && config.node.role != "validator")
                {
                    LOG_ERROR << "Invalid role value observer|validator";
                    return -1;
                }
                d["node"]["role"] = config.node.role;
            }

            if (!config.node.history.empty())
            {
                if (config.node.history != "full" && config.node.history != "custom")
                {
                    LOG_ERROR << "Invalid history value full|custom";
                    return -1;
                }
                d["node"]["history"] = config.node.history;
            }

            if (config.node.history_config.max_primary_shards.has_value())
                d["node"]["history_config"]["max_primary_shards"] = config.node.history_config.max_primary_shards.value();

            if (config.node.history_config.max_raw_shards.has_value())
                d["node"]["history_config"]["max_raw_shards"] = config.node.history_config.max_raw_shards.value();

            if (d["node"]["history"].as<std::string>() == "custom" && d["node"]["history_config"]["max_primary_shards"].as<uint64_t>() == 0)
            {
                LOG_ERROR << "'max_primary_shards' cannot be zero in history=custom mode.";
                return -1;
            }
        }

        // Mesh
        {
            if (config.mesh.idle_timeout.has_value())
                d["mesh"]["idle_timeout"] = config.mesh.idle_timeout.value();

            if (!config.mesh.known_peers.empty())
            {
                jsoncons::ojson known_peers(jsoncons::json_array_arg);
                for (auto &peer : config.mesh.known_peers)
                    known_peers.push_back(peer.host_address + ":" + std::to_string(peer.port));
                d["mesh"]["known_peers"] = known_peers;
            }

            if (config.mesh.msg_forwarding.has_value())
                d["mesh"]["msg_forwarding"] = config.mesh.msg_forwarding.value();

            if (config.mesh.max_connections.has_value())
                d["mesh"]["max_connections"] = config.mesh.max_connections.value();

            if (config.mesh.max_known_connections.has_value())
                d["mesh"]["max_known_connections"] = config.mesh.max_known_connections.value();

            if (config.mesh.max_in_connections_per_host.has_value())
                d["mesh"]["max_in_connections_per_host"] = config.mesh.max_in_connections_per_host.value();

            if (config.mesh.max_bytes_per_msg.has_value())
                d["mesh"]["max_bytes_per_msg"] = config.mesh.max_bytes_per_msg.value();

            if (config.mesh.max_bytes_per_min.has_value())
                d["mesh"]["max_bytes_per_min"] = config.mesh.max_bytes_per_min.value();

            if (config.mesh.max_bad_msgs_per_min.has_value())
                d["mesh"]["max_bad_msgs_per_min"] = config.mesh.max_bad_msgs_per_min.value();

            if (config.mesh.max_bad_msgsigs_per_min.has_value())
                d["mesh"]["max_bad_msgsigs_per_min"] = config.mesh.max_bad_msgsigs_per_min.value();

            if (config.mesh.max_dup_msgs_per_min.has_value())
                d["mesh"]["max_dup_msgs_per_min"] = config.mesh.max_dup_msgs_per_min.value();

            if (config.mesh.peer_discovery.enabled.has_value())
                d["mesh"]["peer_discovery"]["enabled"] = config.mesh.peer_discovery.enabled.value();

            if (config.mesh.peer_discovery.interval.has_value())
                d["mesh"]["peer_discovery"]["interval"] = config.mesh.peer_discovery.interval.value();
        }

        // User
        {
            if (config.user.idle_timeout.has_value())
                d["user"]["idle_timeout"] = config.user.idle_timeout.value();

            if (config.user.max_bytes_per_msg.has_value())
                d["user"]["max_bytes_per_msg"] = config.user.max_bytes_per_msg.value();

            if (config.user.max_bytes_per_min.has_value())
                d["user"]["max_bytes_per_min"] = config.user.max_bytes_per_min.value();

            if (config.user.max_bad_msgs_per_min.has_value())
                d["user"]["max_bad_msgs_per_min"] = config.user.max_bad_msgs_per_min.value();

            if (config.user.max_connections.has_value())
                d["user"]["max_connections"] = config.user.max_connections.value();

            if (config.user.max_in_connections_per_host.has_value())
                d["user"]["max_in_connections_per_host"] = config.user.max_in_connections_per_host.value();

            if (config.user.concurrent_read_requests.has_value())
                d["user"]["concurrent_read_requests"] = config.user.concurrent_read_requests.value();
        }

        // Hpfs
        {
            if (!config.hpfs.log.log_level.empty())
                d["hpfs"]["log"]["log_level"] = config.hpfs.log.log_level;
        }

        // Log
        {
            if (!config.log.log_level.empty())
                d["log"]["log_level"] = config.log.log_level;

            if (config.log.max_mbytes_per_file.has_value())
                d["log"]["max_mbytes_per_file"] = config.log.max_mbytes_per_file.value();

            if (config.log.max_file_count.has_value())
                d["log"]["max_file_count"] = config.log.max_file_count.value();

            if (!config.log.loggers.empty())
            {
                jsoncons::ojson loggers(jsoncons::json_array_arg);
                for (auto &log : config.log.loggers)
                    loggers.push_back(log);
                d["log"]["loggers"] = loggers;
            }
        }
        return 0;
    }

    /**
     * Create new user and install dependencies and populate id and username.
     * @param user_id Uid of the created user to be populated.
     * @param username Username of the created user to be populated.
     * @param max_cpu_us CPU quota allowed for this user.
     * @param max_mem_kbytes Memory quota allowed for this user.
     * @param max_swap_kbytes Swap memory quota allowed for this user.
     * @param storage_kbytes Disk quota allowed for this user.
     * @param instance_ports Ports assigned to the instance.
     */
    int install_user(
        int &user_id, std::string &username, const size_t max_cpu_us, const size_t max_mem_kbytes, const size_t max_swap_kbytes, const size_t storage_kbytes,
        std::string_view container_name, const ports instance_ports, std::string_view docker_image, std::string_view outbound_ipv6, std::string_view outbound_net_interface)
    {
        const std::vector<std::string_view> input_params = {
            std::to_string(max_cpu_us),
            std::to_string(max_mem_kbytes),
            std::to_string(max_swap_kbytes),
            std::to_string(storage_kbytes),
            container_name,
            std::to_string(contract_ugid.uid),
            std::to_string(contract_ugid.gid),
            std::to_string(instance_ports.peer_port),
            std::to_string(instance_ports.user_port),
            std::to_string(instance_ports.gp_tcp_port_start),
            std::to_string(instance_ports.gp_udp_port_start),
            docker_image,
            conf::cfg.docker.registry_address,
            outbound_ipv6,
            outbound_net_interface};
        std::vector<std::string> output_params;
        if (util::execute_bash_file(conf::ctx.user_install_sh, output_params, input_params) == -1)
            return -1;

        if (strncmp(output_params.at(output_params.size() - 1).data(), "INST_SUC", 8) == 0) // If success.
        {
            if (util::stoi(output_params.at(0), user_id) == -1)
            {
                LOG_ERROR << "Create user error: Invalid user id.";
                return -1;
            }
            username = output_params.at(1);
            LOG_INFO << "Created new user : " << username << ", uid : " << user_id;
            return 0;
        }
        else if (strncmp(output_params.at(output_params.size() - 1).data(), "INST_ERR", 8) == 0) // If error.
        {
            const std::string error = output_params.at(0);
            LOG_ERROR << "User creation error : " << error;
            return -1;
        }
        else
        {
            const std::string error = output_params.at(0);
            LOG_ERROR << "Unknown user creation error : " << error;
            return -1;
        }
    }

    /**
     * Delete the given user and remove dependencies.
     * @param username Username of the user to be deleted.
     * @param instance_ports Ports assigned to the instance.
     * @param instance_name Name of the instance.
     */
    int uninstall_user(std::string_view username, const ports assigned_ports, std::string_view instance_name)
    {
        const std::vector<std::string_view> input_params = {
            username,
            std::to_string(assigned_ports.peer_port),
            std::to_string(assigned_ports.user_port),
            std::to_string(assigned_ports.gp_tcp_port_start),
            std::to_string(assigned_ports.gp_udp_port_start),
            instance_name};
        std::vector<std::string> output_params;
        if (util::execute_bash_file(conf::ctx.user_uninstall_sh, output_params, input_params) == -1)
            return -1;

        // const std::string contract_dir = util::get_user_contract_dir(info.username, container_name);
        if (strncmp(output_params.at(output_params.size() - 1).data(), "UNINST_SUC", 8) == 0) // If success.
        {
            LOG_INFO << "Deleted the user : " << username;
            return 0;
        }
        if (strncmp(output_params.at(output_params.size() - 1).data(), "UNINST_ERR", 8) == 0) // If error.
        {
            const std::string error = output_params.at(0);
            LOG_ERROR << "User removing error : " << error;
            return -1;
        }
        else
        {
            const std::string error = output_params.at(0);
            LOG_ERROR << "Unknown user removing error : " << error;
            return -1;
        }
    }

    /**
     * Get the instance list except destroyed instances from the database.
     * @param instances List of instances to be populated.
     */
    void get_instance_list(std::vector<hp::instance_info> &instances)
    {
        sqlite::get_instance_list(db, instances);
    }

    /**
     * Get the leases list from message board database.
     * @param leases List of leases to be populated.
     */
    void get_lease_list(std::vector<hp::lease_info> &leases)
    {
        const std::string db_mb_path = conf::ctx.data_dir + "/mb-xrpl/mb-xrpl.sqlite";
        if (sqlite::open_db(db_mb_path, &db_mb, true) == -1)
        {
            LOG_ERROR << "Error preparing messageboard database in " << db_mb_path;
            return;
        }
        sqlite::get_lease_list(db_mb, leases);
        sqlite::close_db(&db_mb);
    }

    /**
     * Get the instance with given name from the database, skip if destroyed.
     * @param error_msg Error message if any.
     * @param container_name Name of the instance
     * @param instance Instance info ref to be populated.
     * @return 0 on success and -1 on error.
     */
    int get_instance(std::string &error_msg, std::string_view container_name, hp::instance_info &instance)
    {
        if (sqlite::get_instance(db, container_name, instance) == -1)
        {
            error_msg = DOCKER_CONTAINER_NOT_FOUND;
            LOG_ERROR << "No instace with name: " << container_name << ".";
            return -1;
        }

        return 0;
    }
    /**
     * Populate the given vector with vacant ports which are not already assigned.
     * @param vacant_ports Ports vector to hold port pairs from database.
     */
    void get_vacant_ports_list(std::vector<hp::ports> &vacant_ports)
    {
        const int gp_tcp_port_count = 2;
        const int gp_udp_port_count = 2;

        // get all instances
        std::vector<hp::instance_info> instances;
        get_instance_list(instances);

        // no instances
        if (instances.empty())
        {
            return;
        }

        // Get the max instance
        const std::vector<hp::instance_info>::iterator element_max_peer_port = std::max_element(instances.begin(), instances.end(),
                                                                                                [](const hp::instance_info &a, const hp::instance_info &b)
                                                                                                {
                                                                                                    return (uint16_t)(a.assigned_ports.user_port) < (uint16_t)(b.assigned_ports.user_port);
                                                                                                });

        ports init_ports = {(uint16_t)(conf::cfg.hp.init_peer_port), (uint16_t)(conf::cfg.hp.init_user_port), (uint16_t)(conf::cfg.hp.init_gp_tcp_port), (uint16_t)(conf::cfg.hp.init_gp_udp_port)};

        // Keep increasing init port (peer port) until it reaches max port
        // If init port values did not match with an item in the instances list, add init port values to vacant ports list.
        while (init_ports.peer_port < element_max_peer_port->assigned_ports.peer_port)
        {

            bool is_item_available = std::find_if(instances.begin(), instances.end(), [init_ports](const instance_info &instance)
                                                  { return instance.assigned_ports.peer_port == init_ports.peer_port; }) != instances.end();

            if (!is_item_available)
            {
                vacant_ports.push_back(init_ports);
            }

            init_ports.peer_port++;
            init_ports.user_port++;
            init_ports.gp_tcp_port_start += gp_tcp_port_count;
            init_ports.gp_udp_port_start += gp_udp_port_count;
        }
    }
    /**
     * Check whether there's a pending reboot and cgrules service is running and configured.
     * @return true if active and configured otherwise false.
     */
    bool system_ready()
    {
        char buffer[20];

        if (util::execute_bash_cmd(CGRULE_ACTIVE, buffer, 20) == -1)
            return false;

        // Check cgrules service status is active.
        if (strncmp(buffer, "active", 6) != 0)
        {
            LOG_ERROR << "Cgrules service is inactive.";
            return false;
        }

        // Check cgrules cpu and memory mounts exist.
        if (!util::is_dir_exists(CGRULE_CPU_DIR) || !util::is_dir_exists(CGRULE_MEM_DIR))
        {
            LOG_ERROR << "Cgrules cpu or memory mounts does not exist.";
            return false;
        }

        // Check cgrules config exist and configured.
        int fd = open(CGRULE_CONF, O_RDONLY);
        if (fd == -1)
        {
            LOG_ERROR << errno << ": Error opening the cgrules config file.";
            return false;
        }

        std::string buf;
        if (util::read_from_fd(fd, buf, 0) == -1)
        {
            LOG_ERROR << errno << ": Error reading the cgrules config file.";
            close(fd);
            return false;
        }

        close(fd);

        if (!std::regex_search(buf, std::regex(CGRULE_REGEXP)))
        {
            LOG_ERROR << "Cgrules config entry does not exist.";
            return false;
        }

        // Check there's a pending reboot.
        if (util::is_file_exists(REBOOT_FILE))
        {
            fd = open(REBOOT_FILE, O_RDONLY);
            if (fd == -1)
            {
                LOG_ERROR << errno << ": Error opening the reboot file.";
                return false;
            }

            if (util::read_from_fd(fd, buf, 0) == -1)
            {
                LOG_ERROR << errno << ": Error reading the reboot file.";
                close(fd);
                return false;
            }

            close(fd);

            if (std::regex_search(buf, std::regex(REBOOT_REGEXP)))
            {
                LOG_ERROR << "There's a pending reboot.";
                return false;
            }
        }

        return true;
    }
} // namespace hp
