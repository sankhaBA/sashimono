cmake_minimum_required(VERSION 3.16)
project(sagent)

# Force build type to Release build.
set(CMAKE_BUILD_TYPE Release)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY build)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY build)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY build)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Werror")

#-------Bootstrap contract-------

add_executable(bootstrap_contract
    evernode-bootstrap-contract/src/bootstrap_contract.cpp
)

#-------Sashi CLI-------

add_executable(sashi
    sashi-cli/cli-manager.cpp
    sashi-cli/main.cpp
)

target_link_libraries(sashi
    libboost_stacktrace_backtrace.a
    ${CMAKE_DL_LIBS} # Needed for stacktrace support
)

#-------Sashimono Agent-------

add_subdirectory(src/killswitch)

add_executable(sagent
    src/conf.cpp
    src/comm/comm_handler.cpp
    src/util/util.cpp
    src/salog.cpp
    src/crypto.cpp
    src/sqlite.cpp
    src/hp_manager.cpp
    src/hpfs_manager.cpp
    src/msg/msg_parser.cpp
    src/msg/json/msg_json.cpp
    src/main.cpp
)

target_link_libraries(sagent
    killswitch
    libsodium.a
    libboost_stacktrace_backtrace.a
    sqlite3
    pthread
    ${CMAKE_DL_LIBS} # Needed for stacktrace support
)

add_dependencies(sagent
    bootstrap_contract
    sashi
)

add_custom_command(TARGET sagent POST_BUILD
    COMMAND bash -c "cp -r ./dependencies/{hpfs,user-install.sh,user-firewall.sh,dns_evernode.sh,user-uninstall.sh} ./build/"
    COMMAND tar xf ./dependencies/contract_template.tar -C ./build/ --no-same-owner
    COMMAND cp ./dependencies/hp.cfg ./build/contract_template/cfg/
    COMMAND cp ./evernode-bootstrap-contract/src/bootstrap_upgrade.sh ./build/contract_template/contract_fs/seed/state/
    COMMAND mv ./build/bootstrap_contract ./build/contract_template/contract_fs/seed/state/
    COMMAND ./installer/docker-install.sh ./build/dockerbin
    COMMAND npm --prefix ./mb-xrpl ci && npm run --prefix ./mb-xrpl build
    COMMAND npm --prefix ./reputationd ci && npm run --prefix ./reputationd build
    COMMAND npm --prefix ./reputationd/delegate-hook ci && npm run --prefix ./reputationd/delegate-hook build
)

target_precompile_headers(sagent PUBLIC src/pchheader.hpp)

# Add target to generate the installer setup.
add_custom_target(installer
  COMMAND mkdir -p ./build/installer
  COMMAND bash -c "cp -r ./build/{sagent,sashi,hpfs,user-install.sh,user-firewall.sh,dns_evernode.sh,user-uninstall.sh,contract_template} ./build/installer/"
  COMMAND bash -c "cp -r ./installer/{docker-install.sh,docker-registry-install.sh,docker-registry-uninstall.sh,prereq.sh,sashimono-install.sh,sashimono-uninstall.sh} ./build/installer/"
  COMMAND bash -c "cp -r ./dependencies/{user-cgcreate.sh,libblake3.so} ./build/installer/"
  COMMAND bash -c "cp -r ./evernode-license.pdf ./build/installer/"
  COMMAND bash -c "cp -r ./mb-xrpl/dist ./build/installer/mb-xrpl"
  COMMAND bash -c "cp -r ./reputationd/dist ./build/installer/reputationd"
  COMMAND mkdir -p ./build/installer/reputationd/delegate/
  COMMAND bash -c "cp -r ./reputationd/delegate-hook/dist/hook-setup/* ./build/installer/reputationd/delegate/"

  COMMAND tar cfz ./build/installer.tar.gz --sort=name --owner=0 --group=0 --numeric-owner --directory=./build/ installer
  COMMAND rm -r ./build/installer

  # js helper for installer setup.
  COMMAND npm --prefix ./installer/jshelper ci && npm run --prefix ./installer/jshelper build
  COMMAND tar cfz ./build/setup-jshelper.tar.gz --sort=name --owner=0 --group=0 --numeric-owner --directory=./installer/jshelper/ dist
)
set_target_properties(installer PROPERTIES EXCLUDE_FROM_ALL TRUE)
add_dependencies(installer sagent)
