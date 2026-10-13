#!/bin/sh

# Load acme.sh helper functions
# . "${0%/*}/acme.sh"

# Function to ADD a DNS TXT record
dns_evernode_add() {
  full_domain="$1"                # The full domain (e.g., _acme-challenge.example.com)
  txtvalue="$2"                   # The TXT record value to add
  apicall_success="false"         # variable used to keep tabs if API call was a success
  api_subdomain="https://dnsapi." # subdomain that API is setup on the evernode
  nameserver_override="@${EVERNODE_DNS_RESOLVER:-8.8.8.8}"  # nameserver for all the "digs", not the host default one. Set by user-install.sh (proxy.dns_resolver).

  _info "### Evernode DNS v.96 script running, this will collect all name servers that are held within $full_domain"
  _info "### then it will poll each name server to add the TXT record, (substituting subdomain for ${api_subdomain}) as long as one works the script will continue."

  # Step 1: Fetch authoritative nameservers for the parent domain (_acme-challenge.subdomain.main.com -> subdomain.main.com)
  parent_domain="${full_domain#*.}"
  # make sure we have zone correct
  dots=$(echo "$parent_domain" | tr -cd '.' | wc -c)
  if [ "$dots" -gt 1 ]; then
    zone_parent_domain=$(dig +trace +time=1 +tries=1 "$parent_domain" "$nameserver_override" | 
        grep -v "^;" | 
        sed -n 's/^\([^[:space:]]\+\)[[:space:]]\+[0-9]\+[[:space:]]\+IN[[:space:]]\+NS[[:space:]].*/\1/p' | 
        tail -n1)
  else
    zone_parent_domain="$parent_domain"
  fi
  if [ -z "$zone_parent_domain" ]; then
    _err "Unable to determine the authoritative zone for $full_domain."
    return 1
  fi
  _info "Authoritative zone for $full_domain is $zone_parent_domain."

  # now we 100% have zone, we can get all nameservers of root domain, ready for next step
  ns_parent_domain=$(dig +short NS "$zone_parent_domain" "$nameserver_override")
  if [ -z "$ns_parent_domain" ]; then
    _err "No authoritative nameservers found for $parent_domain."
    return 1
  else
    _info "nameserver list secured, with $(echo "$ns_parent_domain" | wc -l) in list."
    _debug "list of nameserver(s):\n$ns_parent_domain"
  fi

  # Step 2: Iterate through the nameservers of the root domain. 
  for ns in $ns_parent_domain; do
    _info "Querying $ns for NS records of $full_domain..."

    # Step 3: get full list of "NS records" held for _acme-challenge subdomain for domain we want SSL for.
    ns_challenge_domain=$(dig +norecurse +noall +authority NS "$full_domain" @"$ns")

    # process the above NS records, store in new variable, so we can check validity (using sed to comply with acme.sh hook plugin environment)
    ns_records=$(echo "$ns_challenge_domain" | sed -n '/IN[[:space:]]\+NS/{s/.*[[:space:]]\([^[:space:]]\+\)$/\1/;p}')

    # Check if processed response is empty, if so, try next name server.
    if [ -z "$ns_records" ]; then
      _info "error in response from $ns. Trying next nameserver..."
      _info "processed response \$ns_records:\n$ns_records"
      _info "actual dig response from $ns:\n$ns_challenge_domain"
      continue
    else
      _info "good response from $ns, with a list of $(echo "$ns_records" | wc -l) NS records to check..."
      _debug "list of NS records(s):\n$ns_challenge_domain"
    fi

    # Step 4: iterate through each NS record from the pre-prepared variable in Step 3
    for ns_record in $ns_records; do
      _info "Processing NS record: $ns_record"

      # Extract the domain part (e.g., ns1.example.com → example.com) and add subdomain of API
      ns_domain="${ns_record#*.}"
      api_domain="${api_subdomain}${ns_domain}/addtxt"
      _debug "using URL ${api_domain} for API command"

      # Step 5: Use _post() to send the API request
      _post '{"domain": "'"${full_domain}"'", "txt": "'"${txtvalue}"'"}' "${api_domain}" "" "POST" "application/json"
      _debug "response:${response}"

      # Check if the API call was successful
      if _contains "$response" "successfully"; then
        _info "Successfully updated $full_domain TXT record using API URL ${api_domain}"
        apicall_success="true"
      else
        _err "Failed to update TXT record for domain $full_domain using API URL ${api_domain}"
      fi
    done

    if [ "$apicall_success" = "true" ]; then
      _info "overall success in a setting a TXT record"
      _info "###### script return"
      return 0
    else
      _err "overall error in setting any TXT records"
      _info "###### script return"
      return 1
    fi
  done
  _err "overall error in setting any TXT records"
  _info "###### script return"
  return 1
}

################################################################################################################################################
# Function to REMOVE a DNS TXT record
dns_evernode_rm() {
  full_domain="$1"                # The full domain (e.g., _acme-challenge.example.com)
  txtvalue="$2"                   # The TXT record value to add
  apicall_success="false"         # variable used to keep tabs if API call was a success
  api_subdomain="https://dnsapi." # subdomain that API is setup on the evernode
  nameserver_override="@${EVERNODE_DNS_RESOLVER:-8.8.8.8}"  # nameserver for all the "digs", not the host default one. Set by user-install.sh (proxy.dns_resolver).

  _info "### Evernode DNS v.96 script running, this will collect all name servers that are held within $full_domain"
  _info "### then it will poll each name server to now remove the TXT record, (substituting subdomain for ${api_subdomain})."

  # Step 1: Fetch authoritative nameservers for the parent domain (_acme-challenge.subdomain.main.com -> subdomain.main.com)
  parent_domain="${full_domain#*.}"
  # make sure we have zone correct
  dots=$(echo "$parent_domain" | tr -cd '.' | wc -c)
  if [ "$dots" -gt 1 ]; then
    zone_parent_domain=$(dig +trace +time=1 +tries=1 "$parent_domain" "$nameserver_override" | 
        grep -v "^;" | 
        sed -n 's/^\([^[:space:]]\+\)[[:space:]]\+[0-9]\+[[:space:]]\+IN[[:space:]]\+NS[[:space:]].*/\1/p' | 
        tail -n1)
  else
    zone_parent_domain="$parent_domain"
  fi
  if [ -z "$zone_parent_domain" ]; then
    _err "Unable to determine the authoritative zone for $full_domain."
    return 1
  fi
  _info "Authoritative zone for $full_domain is $zone_parent_domain."

  # now we 100% have zone, we can get all nameservers of root domain, ready for next step
  ns_parent_domain=$(dig +short NS "$zone_parent_domain" "$nameserver_override")
  if [ -z "$ns_parent_domain" ]; then
    _err "No authoritative nameservers found for $parent_domain."
    return 1
  else
    _info "nameserver list secured, with $(echo "$ns_parent_domain" | wc -l) in list."
    _debug "list of nameserver(s):\n$ns_parent_domain"
  fi

  # Step 2: Iterate through the nameservers of the root domain. 
  for ns in $ns_parent_domain; do
    _info "Querying $ns for NS records of $full_domain..."

    # Step 3: get full list of "NS records" held for _acme-challenge subdomain for domain we want SSL for.
    ns_challenge_domain=$(dig +norecurse +noall +authority NS "$full_domain" @"$ns")

    # process the above NS records, store in new variable, so we can check validity (using sed to comply with acme.sh hook plugin environment)
    ns_records=$(echo "$ns_challenge_domain" | sed -n '/IN[[:space:]]\+NS/{s/.*[[:space:]]\([^[:space:]]\+\)$/\1/;p}')

    # Check if processed response is empty, if so, try next name server.
    if [ -z "$ns_records" ]; then
      _info "error in response from $ns. Trying next nameserver..."
      _info "processed response \$ns_records:$ns_records"
      _info "actual dig response from $ns:$ns_challenge_domain"
      continue
    else
      _info "good response from $ns, with a list of $(echo "$ns_records" | wc -l) NS records to check..."
      _debug "list of NS records(s):\n$ns_challenge_domain"
    fi

    # Step 4: iterate through each NS record from the pre-prepared variable in Step 3
    for ns_record in $ns_records; do
      _info "Processing NS record: $ns_record"

      # Extract the domain part (e.g., ns1.example.com → example.com) and add subdomain of API
      ns_domain="${ns_record#*.}"
      api_domain="${api_subdomain}${ns_domain}/rmtxt"
      _debug "using URL ${api_domain} for API command"

      # Step 5: Use _post() to send the API request
      _post '{"domain": "'"${full_domain}"'", "txt": "'"${txtvalue}"'"}' "${api_domain}" "" "POST" "application/json"
      _debug "response:${response}"

      # Check if the API call was successful
      if _contains "$response" "successfully"; then
        _info "Successfully removed $full_domain TXT record using API URL ${api_domain}"
        apicall_success="true"
      else
        _err "Failed to remove TXT record for domain $full_domain using API URL ${api_domain}"
      fi
    done

    if [ "$apicall_success" = "true" ]; then
      _info "success in removing a TXT record"
      _info "###### script return"
      return 0
    else
      _err "error in removing any TXT records"
      _info "###### script return"
      return 1
    fi
  done
  _err "overall error in setting any TXT records"
  _info "###### script return"
  return 1
}