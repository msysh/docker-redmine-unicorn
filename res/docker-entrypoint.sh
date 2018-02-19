#!/bin/bash
set -e

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

case "$1" in
	unicorn)

		if [ ! -f './config/database.yml' ]; then
			file_env 'REDMINE_DB_MYSQL'
			file_env 'REDMINE_DB_POSTGRES'
			file_env 'REDMINE_DB_SQLSERVER'
		
			if [ "$MYSQL_PORT_3306_TCP" ] && [ -z "$REDMINE_DB_MYSQL" ]; then
				export REDMINE_DB_MYSQL='mysql'
			elif [ "$POSTGRES_PORT_5432_TCP" ] && [ -z "$REDMINE_DB_POSTGRES" ]; then
				export REDMINE_DB_POSTGRES='postgres'
			fi
		
			if [ "$REDMINE_DB_MYSQL" ]; then
				adapter='mysql2'
				host="$REDMINE_DB_MYSQL"
				file_env 'REDMINE_DB_PORT' '3306'
				file_env 'REDMINE_DB_USERNAME' "${MYSQL_ENV_MYSQL_USER:-root}"
				file_env 'REDMINE_DB_PASSWORD' "${MYSQL_ENV_MYSQL_PASSWORD:-${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}"
				file_env 'REDMINE_DB_DATABASE' "${MYSQL_ENV_MYSQL_DATABASE:-${MYSQL_ENV_MYSQL_USER:-redmine}}"
				file_env 'REDMINE_DB_ENCODING' ''
			elif [ "$REDMINE_DB_POSTGRES" ]; then
				adapter='postgresql'
				host="$REDMINE_DB_POSTGRES"
				file_env 'REDMINE_DB_PORT' '5432'
				file_env 'REDMINE_DB_USERNAME' "${POSTGRES_ENV_POSTGRES_USER:-postgres}"
				file_env 'REDMINE_DB_PASSWORD' "${POSTGRES_ENV_POSTGRES_PASSWORD}"
				file_env 'REDMINE_DB_DATABASE' "${POSTGRES_ENV_POSTGRES_DB:-${REDMINE_DB_USERNAME:-}}"
				file_env 'REDMINE_DB_ENCODING' 'utf8'
			elif [ "$REDMINE_DB_SQLSERVER" ]; then
				adapter='sqlserver'
				host="$REDMINE_DB_SQLSERVER"
				file_env 'REDMINE_DB_PORT' '1433'
				file_env 'REDMINE_DB_USERNAME' ''
				file_env 'REDMINE_DB_PASSWORD' ''
				file_env 'REDMINE_DB_DATABASE' ''
				file_env 'REDMINE_DB_ENCODING' ''
			else
				echo >&2
				echo >&2 'warning: missing REDMINE_DB_MYSQL, REDMINE_DB_POSTGRES, or REDMINE_DB_SQLSERVER environment variables'
				echo >&2
				echo >&2 '*** Using sqlite3 as fallback. ***'
				echo >&2
				
				adapter='sqlite3'
				host='localhost'
				file_env 'REDMINE_DB_PORT' ''
				file_env 'REDMINE_DB_USERNAME' 'redmine'
				file_env 'REDMINE_DB_PASSWORD' ''
				file_env 'REDMINE_DB_DATABASE' 'sqlite/redmine.db'
				file_env 'REDMINE_DB_ENCODING' 'utf8'
				
				mkdir -p "$(dirname "$REDMINE_DB_DATABASE")"
				chown -R redmine:redmine "$(dirname "$REDMINE_DB_DATABASE")"
			fi
			
			REDMINE_DB_ADAPTER="$adapter"
			REDMINE_DB_HOST="$host"
			echo "$RAILS_ENV:" > config/database.yml
			for var in \
				adapter \
				host \
				port \
				username \
				password \
				database \
				encoding \
			; do
				env="REDMINE_DB_${var^^}"
				val="${!env}"
				[ -n "$val" ] || continue
				echo "  $var: \"$val\"" >> config/database.yml
			done
			
		else
			# parse the database config to get the database adapter name
			# so we can use the right Gemfile.lock
			adapter="$(
				ruby -e "
					require 'yaml'
					conf = YAML.load_file('./config/database.yml')
					puts conf['$RAILS_ENV']['adapter']
				"
			)"
		fi
		
		# ensure the right database adapter is active in the Gemfile.lock
		echo `date '+%Y/%m/%d %H:%M:%S'` $0 "[INFO] Adapter is ${adapter}."
		cp "Gemfile.lock.${adapter}" Gemfile.lock

		# install additional gems for Gemfile.local and plugins
		echo `date '+%Y/%m/%d %H:%M:%S'` $0 "[INFO] Start bundle check."
		bundle check || bundle install --without development test

		if [ ! -s config/secrets.yml ]; then
			file_env 'REDMINE_SECRET_KEY_BASE'
			if [ "$REDMINE_SECRET_KEY_BASE" ]; then
				cat > 'config/secrets.yml' <<-YML
					$RAILS_ENV:
						secret_key_base: "$REDMINE_SECRET_KEY_BASE"
				YML
			elif [ ! -f /usr/src/redmine/config/initializers/secret_token.rb ]; then
				rake generate_secret_token
			fi
		fi
		
		if [ ! -z $UNICORN_LISTEN_PORT ]; then
			PORT_OPT="-p $UNICORN_LISTEN_PORT"
		else
			PORT_OPT=""
		fi

		if [ ! -z $REDMINE_URL_PATH ]; then
			URL_OPT="--path $REDMINE_URL_PATH"
		else
			URL_OPT=""
		fi

		echo `date '+%Y/%m/%d %H:%M:%S'` $0 "[INFO] Start making directories."
		#
		mkdir -p tmp/pids tmp/pdf
		
		# https://www.redmine.org/projects/redmine/wiki/RedmineInstall#Step-8-File-system-permissions
		chown -R redmine:redmine files log tmp/pids tmp/pdf public/plugin_assets
		
		# directories 755, files 644:
		chmod -R ugo-x,u+rwX,go+rX,go-w files log tmp public/plugin_assets
		
		echo `date '+%Y/%m/%d %H:%M:%S'` $0 "[INFO] Start db migrate."
		RAILS_ENV=production gosu redmine bundle exec rake db:migrate

		echo `date '+%Y/%m/%d %H:%M:%S'` $0 "[INFO] Start plugin migrate."
		RAILS_ENV=production gosu redmine bundle exec rake redmine:plugins:migrate

		echo `date '+%Y/%m/%d %H:%M:%S'` $0 "[INFO] Start loading default data.."
		RAILS_ENV=production REDMINE_LANG=ja gosu redmine bundle exec rake redmine:load_default_data
		
		if [ "$1" != 'rake' -a -n "$REDMINE_PLUGINS_MIGRATE" ]; then
			gosu redmine rake redmine:plugins:migrate
		fi
		
		# remove PID file to enable restarting the container
		rm -f /usr/src/redmine/tmp/pids/server.pid
		
		echo `date '+%Y/%m/%d %H:%M:%S'` $0 "[INFO] Start unicorn."
		RAILS_SERVE_STATIC_FILES=true gosu redmine bundle exec unicorn_rails -E production -c config/unicorn.rb $PORT_OPT $URL_OPT
		exit
		;;
	rake)
		set -- gosu redmine "$@"
		exit
		;;
esac

exec "$@"
