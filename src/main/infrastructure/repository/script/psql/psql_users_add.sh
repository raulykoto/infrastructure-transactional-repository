#!/bin/sh

# Default parameters.
DEBUG=${DEBUG:=true}
DEBUG_OPT=

# If not exist
if [ -z "$LDAP_HOST" ]; then
	${DEBUG} && echo MOUNTING LDAP_HOST VAR - ${LDAP_URI}:${LDAP_PORT}
	LDAP_HOST=${LDAP_URI}:${LDAP_PORT}
fi

# For each permission.
#USER_ROLE_GROUP_VARS=$(env | grep "PSQL_ROLE_" | sed -e "s/PSQL_ROLE_/role|/")
USER_READ_GROUP_VARS=$(env | grep "PSQL_READ_SCHEMA_" | sed -e "s/PSQL_READ_SCHEMA_/read|/" -e "s/_TABLE_/|/")
USER_WRITE_GROUP_VARS=$(env | grep "PSQL_WRITE_SCHEMA_" | sed -e "s/PSQL_WRITE_SCHEMA_/write|/" -e "s/_TABLE_/|/")
USER_GROUP_VARS=$(echo "${USER_READ_GROUP_VARS}\n${USER_WRITE_GROUP_VARS}")
${DEBUG} && echo "USER_GROUP_VARS=${USER_GROUP_VARS}"

for USER_GROUP_VAR in ${USER_GROUP_VARS}
do
	# Gets the group variables.
	USER_GROUP_PROC_VAR=${USER_GROUP_VAR}
	USER_GROUPS=$( echo "${USER_GROUP_PROC_VAR}" | sed -e "s/.*=//" )
	USER_GROUP_PROC_VAR=$( echo "${USER_GROUP_PROC_VAR}" | sed -e "s/=${USER_GROUPS}//" )
	USER_GROUP_PERMISSION=$( echo "${USER_GROUP_PROC_VAR}" | sed -e "s/|.*//" )
	USER_GROUP_PROC_VAR=$( echo "${USER_GROUP_PROC_VAR}" | sed -e "s/${USER_GROUP_PERMISSION}|//" )
	USER_GROUP_SCHEMA=$( echo "${USER_GROUP_PROC_VAR}" | sed -e "s/|.*//" )
	USER_GROUP_PROC_VAR=$( echo "${USER_GROUP_PROC_VAR}" | sed -e "s/${USER_GROUP_SCHEMA}|\?//" )
	USER_GROUP_TABLE=$( echo "${USER_GROUP_PROC_VAR}" )
	
	# Prepares the group variables.
	USER_GROUP_SCHEMA=$( echo ${USER_GROUP_SCHEMA} | tr "[:upper:]" "[:lower:]" )
	USER_GROUP_TABLE=$( echo ${USER_GROUP_TABLE} | tr "[:upper:]" "[:lower:]" )
	USER_GROUP_PERMISSION_GRANT=$( [ "write" = ${USER_GROUP_PERMISSION} ] && echo "ALL" )
	${DEBUG} && echo "USER_GROUP_PERMISSION=${USER_GROUP_PERMISSION}"
	${DEBUG} && echo "USER_GROUP_SCHEMA=${USER_GROUP_SCHEMA}"
	${DEBUG} && echo "USER_GROUP_TABLE=${USER_GROUP_TABLE}"
	${DEBUG} && echo "USER_GROUP_PERMISSION_GRANT=${USER_GROUP_PERMISSION_GRANT}"
	${DEBUG} && echo "USER_GROUPS=${USER_GROUPS}"
	USER_GROUPS=$( echo "${USER_GROUPS}" | sed -e "s/,/\n/g" )
	GRANT_TYPE="USAGE"
	if [ "$USER_GROUP_PERMISSION" = "write" ]; then GRANT_TYPE="CREATE"; fi 

	# For each group.
	for USER_GROUP in ${USER_GROUPS}
	do
		# Get users from schema.
		SCHEMA_USERS=
		SCHEMA_USERS=$(PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -t -A -q -X -c  "select rolname from pg_namespace pn, pg_catalog.pg_roles r where array_to_string(nspacl,',') like '%'||r.rolname||'%' and pg_catalog.has_schema_privilege(r.rolname, nspname, '$GRANT_TYPE') and nspname = '$USER_GROUP_SCHEMA'" -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE})
		
		${DEBUG} && echo SCHEMA_USERS=${SCHEMA_USERS}
		${DEBUG} && echo "USER_GROUP=${USER_GROUP}"
		# Gets the users to configure permission.
		if [ ! -z "${USER_GROUP}" ]
		then
			${DEBUG} && echo "Getting users from ldap: ${USER_GROUP}"
			USERS=$(ldapsearch -LLL -w "${LDAP_PASSWORD}" -D "${LDAP_USER}" \
			-H "ldap://${LDAP_HOST}" -b "${LDAP_GROUPS}" "(cn=${USER_GROUP})" \
			 | grep memberUid | sed "s/memberUid: //g")
		fi

		# For each user to configure access.
		for CURRENT_USER in ${USERS}
		do
			# Create only if not exist on schema.
			if ! (echo $SCHEMA_USERS | grep -wq $CURRENT_USER)
			then
				# Configures the user permissions.
				${DEBUG} && echo "Creating user ${CURRENT_USER}"
				PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "CREATE USER \"${CURRENT_USER}\" WITH NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN NOREPLICATION;" -U ${POSTGRES_ADMIN_USER} || true
			else
				echo "Skiping - User: $CURRENT_USER already exists for Schema: $USER_GROUP_SCHEMA on Type: $USER_GROUP_PERMISSION"
			fi
		
			# Configures permissions for the user.
			${DEBUG} && echo "Configuring permissions for user ${CURRENT_USER}"
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-CONNECT, TEMPORARY} ON DATABASE \"${POSTGRES_DEFAULT_DATABASE}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE}
			${DEBUG} && echo "GRANT ${USER_GROUP_PERMISSION_GRANT:-CONNECT, TEMPORARY} ON DATABASE \"${POSTGRES_DEFAULT_DATABASE}\" TO \"${CURRENT_USER}\";"
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-USAGE} ON SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE}
			${DEBUG} && echo "GRANT ${USER_GROUP_PERMISSION_GRANT:-USAGE} ON SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";"
			if [ -z "${USER_GROUP_TABLE}" ]
			then
				PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-SELECT} ON ALL TABLES IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE}
				${DEBUG} && echo "GRANT ${USER_GROUP_PERMISSION_GRANT:-SELECT} ON ALL TABLES IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";"
			else 
				PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-SELECT} ON \"${USER_GROUP_SCHEMA}\".\"${USER_GROUP_TABLE}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE}
				${DEBUG} && echo "GRANT ${USER_GROUP_PERMISSION_GRANT:-SELECT} ON \"${USER_GROUP_SCHEMA}\".\"${USER_GROUP_TABLE}\" TO \"${CURRENT_USER}\";"
			fi
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-SELECT} ON ALL SEQUENCES IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE}
			${DEBUG} && echo "GRANT ${USER_GROUP_PERMISSION_GRANT:-SELECT} ON ALL SEQUENCES IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";"
			PGPASSWORD=${POSTGRES_ADMIN_PASSWORD} psql -c "GRANT ${USER_GROUP_PERMISSION_GRANT:-EXECUTE} ON ALL FUNCTIONS IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";" -U ${POSTGRES_ADMIN_USER} ${POSTGRES_DEFAULT_DATABASE}
			${DEBUG} && echo "GRANT ${USER_GROUP_PERMISSION_GRANT:-EXECUTE} ON ALL FUNCTIONS IN SCHEMA \"${USER_GROUP_SCHEMA}\" TO \"${CURRENT_USER}\";"
			
		done
		
	done

done