#!/bin/bash

# /bin/bash -c "$(curl -fsSL nsknet.github.io/ubuntu.sh)"	

function install_postgres_remote()
{

	echo "========================================================================="
	echo "Install POSTGRESQL12"
	
	#https://www.digitalocean.com/community/tutorials/how-to-install-postgresql-on-ubuntu-20-04-quickstart
	apt install -y postgresql-12 postgresql-contrib

	#init database
	echo "init database ========================="
	#sudo /usr/pgsql-12/bin/postgresql-12-setup initdb

	systemctl enable postgresql
	systemctl start postgresql
	systemctl status postgresql --no-pager 


	printf "\nEnter db password for user postgres [no special charaters]: " 
	read db_password
	# #error here!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
	su - postgres -c "psql -U postgres -d postgres -c \"alter user postgres with password '$db_password';\""
	sudo systemctl restart postgresql


	#allow PostgreSQL service.
	#TODO disable the Firewall rule, we will use putty tunel for more sercure
	# sudo firewall-cmd --add-service=postgresql --permanent
	# sudo firewall-cmd --zone=public --add-port=5432/tcp --permanent
	# sudo firewall-cmd --reload

	cp /etc/postgresql/12/main/postgresql.conf /etc/postgresql/12/main/postgresql.conf.bak
	cat > "/etc/postgresql/12/main/postgresql.conf" <<END
#for Ubuntu, centos doesnt have these lines
data_directory = '/var/lib/postgresql/12/main'
hba_file = '/etc/postgresql/12/main/pg_hba.conf'
ident_file = '/etc/postgresql/12/main/pg_ident.conf'
external_pid_file = '/var/run/postgresql/12-main.pid'
include_dir = 'conf.d'


listen_addresses ='*'
max_connections = 100			
shared_buffers = 128MB			
dynamic_shared_memory_type = posix	
max_wal_size = 1GB
min_wal_size = 80MB
log_destination = 'stderr'		
logging_collector = on			
log_directory = 'log'			
log_filename = 'postgresql-%a.log'	
log_truncate_on_rotation = on		
log_rotation_age = 1d			
log_rotation_size = 0			
log_line_prefix = '%m [%p] '		
log_timezone = 'Asia/Ho_Chi_Minh'
datestyle = 'iso, mdy'
timezone = 'Asia/Ho_Chi_Minh'
lc_messages = 'en_US.UTF-8'			
lc_monetary = 'en_US.UTF-8'			
lc_numeric = 'en_US.UTF-8'			
lc_time = 'en_US.UTF-8'				
default_text_search_config = 'pg_catalog.english'
END

	cp /etc/postgresql/12/main/pg_hba.conf /etc/postgresql/12/main/pg_hba.conf.bak
	cat > "/etc/postgresql/12/main/pg_hba.conf" <<END
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# "local" is for Unix domain socket connections only
local   all             all                                     md5
# IPv4 local connections:
host    all             all             127.0.0.1/32            md5
# IPv6 local connections:
host    all             all             ::1/128                 md5
# Allow replication connections from localhost, by a user with the replication privilege.
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            ident
host    replication     all             ::1/128                 ident
# Accept from anywhere
host 	all 			all 			0.0.0.0/0 				md5

END
	systemctl restart postgresql

	echo ""
	echo "Done"
	echo "========================================================================="	
}

function install_fail2ban(){
	echo "========================================================================="
	echo "Installing Fail2ban - SSH brute force protection..."
	
	# Install fail2ban
	apt update
	apt install -y fail2ban
	
	# Backup original config if exists
	if [ -f /etc/fail2ban/jail.conf ]; then
		cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.conf.bak
		echo "Original jail.conf backed up"
	fi
	
	# Create jail.local configuration (this overrides jail.conf)
	cat > "/etc/fail2ban/jail.local" <<END
[DEFAULT]
# Ban IP for 1 hour (3600 seconds)
bantime = 3600

# An IP will be banned if it has generated maxretry failures in last 10 minutes
findtime = 600

# Number of failures before a host gets banned
maxretry = 3

# Whitelist your own IP (localhost)
ignoreip = 127.0.0.1/8 ::1

# Email notifications (optional - leave empty to disable)
destemail = 
sendername = Fail2Ban
mta = sendmail

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
END

	# Enable and start fail2ban service
	systemctl enable fail2ban
	systemctl start fail2ban
	
	# Check status
	echo ""
	echo "Checking Fail2ban status..."
	systemctl status fail2ban --no-pager
	
	echo ""
	echo "========================================================================="
	echo "Fail2ban Installation Complete!"
	echo "========================================================================="
	echo "Configuration:"
	echo "  - Config file: /etc/fail2ban/jail.local"
	echo "  - Log file: /var/log/fail2ban.log"
	echo "  - SSH log: /var/log/auth.log"
	echo ""
	echo "Protection settings:"
	echo "  - Max retry: 3 attempts"
	echo "  - Find time: 10 minutes"
	echo "  - Ban time: 1 hour"
	echo ""
	echo "Useful commands:"
	echo "  - Check status: fail2ban-client status"
	echo "  - Check SSH jail: fail2ban-client status sshd"
	echo "  - Unban IP: fail2ban-client set sshd unbanip <IP>"
	echo "  - View banned IPs: fail2ban-client status sshd"
	echo "========================================================================="
}


function install_php(){
	echo "========================================================================="
	echo "Install PHP"

	sudo yum -y install http://rpms.remirepo.net/enterprise/remi-release-7.rpm
	sudo yum-config-manager --enable remi-php74
	sudo yum -y install php php-common php-opcache php-mcrypt php-cli php-gd php-curl php-mysql  php-mbstring php-fpm
	php --version
	
cat > "/etc/php-fpm.d/www.conf" <<END
[www]
user = nginx
group = nginx
listen = /var/run/php-fpm/php-fpm.sock
listen.allowed_clients = 127.0.0.1
listen.owner = nginx
listen.group = nginx
listen.mode = 0660
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
slowlog = /var/log/php-fpm/www-slow.log
php_admin_value[error_log] = /var/log/php-fpm/www-error.log
php_admin_flag[log_errors] = on
php_value[session.save_handler] = files
php_value[session.save_path]    = /var/lib/php/session
php_value[soap.wsdl_cache_dir]  = /var/lib/php/wsdlcache
END


cat > "/etc/selinux/config" <<END
SELINUX=disabled
SELINUXTYPE=targeted
END
	#temporarily change the selinux mode from targeted to permissive
	sudo setenforce 0

	chown -R root:nginx /var/lib/php
	sudo systemctl enable php-fpm
	sudo systemctl start php-fpm
	
	echo ""
	echo "Done"
	echo "If you have any permission error, please try to reboot the system"
	echo "========================================================================="
}

function install_netcore(){
	#install netcore
	#https://learn.microsoft.com/en-us/dotnet/core/install/linux-ubuntu-install?tabs=dotnet9&pivots=os-linux-ubuntu-2404
	echo "========================================================================="
	echo "Install Netcore"
	add-apt-repository ppa:dotnet/backports -y
	apt update
	apt install -y dotnet-sdk-6.0 dotnet-sdk-7.0 dotnet-sdk-8.0 dotnet-sdk-8.0 dotnet-sdk-9.0
	echo ""
	echo "Done"
	echo "========================================================================="
}

function install_mongodb(){
	#install mongodb
	#https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/
	#https://www.mongodb.com/docs/manual/administration/install-community/?linux-distribution=ubuntu&linux-package=default&operating-system=linux&search-linux=with-search-linux
	echo "========================================================================="
	echo "Install MongoDB"
	
	# Install prerequisites
	apt install -y gnupg curl
	
	# Import MongoDB public GPG key
	curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
	   sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg \
	   --dearmor
	
	# Detect Ubuntu version
	UBUNTU_CODENAME=$(lsb_release -cs)
	
	# Set repository based on Ubuntu version
	case "$UBUNTU_CODENAME" in
		noble)
			echo "Detected Ubuntu 24.04 (Noble)"
			echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.2 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.2.list
			;;
		jammy)
			echo "Detected Ubuntu 22.04 (Jammy)"
			echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.2 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.2.list
			;;
		focal)
			echo "Detected Ubuntu 20.04 (Focal)"
			echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/8.2 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.2.list
			;;
		*)
			echo "Unknown Ubuntu version: $UBUNTU_CODENAME, using Noble repository"
			echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.2 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.2.list
			;;
	esac
	
	# Update package database
	apt update
	
	# Install MongoDB
	apt install -y mongodb-org
	
	# Enable and start MongoDB service
	systemctl enable mongod.service
	systemctl start mongod
	
	# Check MongoDB status
	systemctl status mongod --no-pager
	
	echo ""
	echo "MongoDB installation completed"
	echo "========================================================================="
}

function install_elastic_kibana(){
	#install Elasticsearch & Kibana
	#https://tecadmin.net/how-to-setup-elasticsearch-on-ubuntu-22-04/
	echo "========================================================================="
	
	wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
	echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-8.x.list 
	apt update
	apt install -y elasticsearch kibana


	cat > "/etc/elasticsearch/elasticsearch.yml" <<END
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node

#Disable SSL
xpack.security.transport.ssl.enabled: false
xpack.security.http.ssl.enabled: false

#Disable Auth
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
END
#sudo nano /etc/kibana/kibana.yml

	cat > "/etc/kibana/kibana.yml" <<END
server.port: 5601
server.host: "127.0.0.1"
elasticsearch.hosts: ["http://127.0.0.1:9200"]

END

	systemctl enable elasticsearch
	service elasticsearch start

	systemctl status elasticsearch  --no-pager

	#systemctl enable kibana
	#service kibana start 
	systemctl status kibana  --no-pager

	echo ""
	echo "If the elastic cannot start, please try to disable SELinux or buy a stronger machine :)"
	echo "If the kibana err, please check by: /usr/share/kibana/bin/kibana -V"
	echo "Please type 'service kibana start' to start the kibana"
	echo "Done"
	echo "========================================================================="
}

function install_nginx(){
	echo "========================================================================="
	echo "Installing NGINX web server..."

	# Install nginx
	apt install -y nginx

	# Enable and start nginx service
	systemctl enable nginx
	systemctl start nginx
	systemctl status nginx --no-pager

	# Create directory structure for nginx configurations
	echo "Creating directory structure..."
	mkdir -p /var/www/nginx/log
	mkdir -p /var/www/nginx/conf.d
	
	# Backup original configuration
	cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
	echo "Original nginx.conf backed up to nginx.conf.bak"

	# Create optimized nginx.conf
	cat > "/etc/nginx/nginx.conf" <<END
user www-data;
worker_processes auto;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
	worker_connections 2048;
	multi_accept on;
}

http {
	# Basic Settings
	sendfile on;
	tcp_nopush on;
	tcp_nodelay on;
	keepalive_timeout 65;
	types_hash_max_size 2048;
	server_tokens off;
	
	# Timeout settings
	client_body_timeout 12;
	client_header_timeout 12;
	send_timeout 10;
	
	# Buffer settings
	client_body_buffer_size 10K;
	client_header_buffer_size 1k;
	client_max_body_size 8m;
	large_client_header_buffers 2 1k;

	# MIME types
	include /etc/nginx/mime.types;
	default_type application/octet-stream;

	# Logging Configuration
	log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
	                '\$status \$body_bytes_sent "\$http_referer" '
	                '"\$http_user_agent" "\$http_x_forwarded_for" '
	                '"\$host" sn="\$server_name" '
	                'rt=\$request_time '
	                'ua="\$upstream_addr" us="\$upstream_status" '
	                'ut="\$upstream_response_time" ul="\$upstream_response_length" '
	                'cs=\$upstream_cache_status';

	access_log /var/www/nginx/log/global-access.log main;
	error_log /var/www/nginx/log/global-error.log warn;

	# Gzip Compression
	gzip on;
	gzip_static on;
	gzip_disable "msie6";
	gzip_vary on;
	gzip_proxied any;
	gzip_comp_level 6;
	gzip_buffers 16 8k;
	gzip_http_version 1.1;
	gzip_min_length 256;
	gzip_types text/plain text/css application/json application/javascript 
	           text/xml application/xml application/xml+rss text/javascript
	           application/vnd.ms-fontobject application/x-font-ttf 
	           font/opentype image/svg+xml;

	# Include virtual host configs
	include /var/www/nginx/conf.d/*.conf;
	include /etc/nginx/conf.d/*.conf;

	# Default server block - reject undefined hosts
	server {
		listen 80 default_server;
		server_name _;
		return 444;
	}
}
END

	# Create custom error pages
	echo "Creating custom error pages..."
	cat > "/usr/share/nginx/html/403.html" <<END
<!DOCTYPE html>
<html>
<head>
	<title>403 Forbidden</title>
	<style>
		body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
		h1 { color: #d9534f; }
	</style>
</head>
<body>
	<h1>403 Forbidden</h1>
	<p>You don't have permission to access this resource.</p>
</body>
</html>
END

	cat > "/usr/share/nginx/html/404.html" <<END
<!DOCTYPE html>
<html>
<head>
	<title>404 Not Found</title>
	<style>
		body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
		h1 { color: #f0ad4e; }
	</style>
</head>
<body>
	<h1>404 Not Found</h1>
	<p>The page you are looking for does not exist.</p>
</body>
</html>
END

	# Test nginx configuration
	echo "Testing nginx configuration..."
	if nginx -t; then
		echo "Nginx configuration is valid"
		systemctl reload nginx
		systemctl restart nginx
	else
		echo "ERROR: Nginx configuration has errors! Please check manually."
		return 1
	fi

	# Configure SELinux for nginx (if SELinux is active)
	if command -v setsebool &> /dev/null; then
		echo "Configuring SELinux for nginx..."
		setsebool -P httpd_can_network_connect on
	fi

	# Configure UFW firewall
	echo "Configuring firewall rules..."
	if command -v ufw &> /dev/null; then
		ufw allow http
		ufw allow https
		ufw --force enable
		echo "Firewall rules added for HTTP and HTTPS"
	else
		echo "UFW not found, skipping firewall configuration"
	fi

	# Set proper permissions
	chown -R www-data:www-data /var/www/nginx
	chmod -R 755 /var/www/nginx

	echo ""
	echo "========================================================================="
	echo "NGINX Installation Complete!"
	echo "========================================================================="
	echo "Directory structure:"
	echo "  - Config files: /var/www/nginx/conf.d/"
	echo "  - Log files: /var/www/nginx/log/"
	echo "  - Main config: /etc/nginx/nginx.conf"
	echo "  - Backup: /etc/nginx/nginx.conf.bak"
	echo ""
	echo "========================================================================="
}



function install_nginx_certbot(){
	yum -y install yum-utils
	yum-config-manager --enable rhui-REGION-rhel-server-extras rhui-REGION-rhel-server-optional
	yum -y install certbot python2-certbot-nginx
	#sudo certbot --nginx
	echo "0 0,12 * * * root python -c 'import random; import time; time.sleep(random.random() * 3600)' && certbot renew" | sudo tee -a /etc/crontab > /dev/null
	
	
	#certbot --nginx certonly --noninteractive --webroot --agree-tos --register-unsafely-without-email -d ${SITE_DOMAIN} 
}

function add_nginx_site(){
	echo "========================================================================="
	echo "Add New Nginx Site"
	echo "========================================================================="
	
	# Step 1: Choose external access method
	echo "How will users access this site from outside?"
	echo "1) To a port without domain name (random port will be assigned)"
	echo "2) To a domain name (you provide the domain)"
	read -p "Enter your choice [1 or 2]: " access_choice
	
	service_name=""
	server_name=""
	external_port=""
	use_domain=false
	
	if [ "$access_choice" == "2" ]; then
		use_domain=true
		printf "\nEnter your domain name (e.g., example.com): "
		read server_name
		service_name="$server_name"
		
		# Handle www subdomain
		server_name_alias="www.$server_name"
		if [[ $server_name == *www* ]]; then
			server_name_alias=${server_name/www./''}
		fi
	else
		printf "\nEnter service name (without spaces, e.g., myapp): "
		read service_name
		server_name="_"
		
		# Generate random external port
		DIFF=$((50000-5000+1))
		external_port=$(($(($RANDOM%$DIFF))+5000))
		echo "External port assigned: $external_port"
	fi
	
	# Step 2: Choose backend type
	echo ""
	echo "What is the backend for this site?"
	echo "1) Already running on local port (you provide the running port)"
	echo "2) Static HTML files"
	echo "3) New .NET Core service"
	read -p "Enter your choice [1, 2, or 3]: " backend_choice
	
	internal_port=""
	internal_address=""
	dll_name=""
	create_dotnet_service=false
	is_static=false
	
	case $backend_choice in
		1)
			printf "\nEnter existing local port or full address (e.g., 5555 or http://192.168.1.2:6666): "
			read internal_input
			
			# Check if it's just a port number or full address
			if [[ $internal_input =~ ^[0-9]+$ ]]; then
				internal_port=$internal_input
				internal_address="http://127.0.0.1:$internal_port"
			else
				internal_address=$internal_input
			fi
			;;
		2)
			is_static=true
			;;
		3)
			create_dotnet_service=true
			printf "\nEnter your .dll file name (e.g., example.dll): "
			read dll_full_name
			
			dll_name="$dll_full_name"
			if [[ $dll_full_name == *dll* ]]; then
				dll_name=${dll_full_name/.dll/''}
			fi
			
			# Generate random internal port
			DIFF=$((50000-5000+1))
			internal_port=$(($(($RANDOM%$DIFF))+5000))
			
			# If using external port, make internal port = external - 1 for easy memory
			if [ "$access_choice" == "1" ]; then
				internal_port=$((external_port-1))
			fi
			
			echo "Internal .NET port: $internal_port"
			;;
	esac
	
	# Create directory structure
	mkdir -p /var/www/nginx/sites/$service_name/public
	mkdir -p /var/www/nginx/sites/$service_name/logs
	mkdir -p /var/www/nginx/sites/$service_name/data
	chmod 777 /var/www/nginx/sites/$service_name
	chown -R www-data:www-data /var/www/nginx/sites/$service_name
	
	# Create nginx configuration
	echo ""
	echo "Creating nginx configuration..."
	
	if [ "$use_domain" = true ]; then
		# Domain-based configuration
		if [ "$is_static" = true ]; then
			# Static HTML site
			cat > "/var/www/nginx/conf.d/$service_name.conf" <<END
server {
	client_max_body_size 200M;
	listen 80;
	server_name $server_name;
	root /var/www/nginx/sites/$service_name/public;
	
	error_log /var/www/nginx/log/$service_name-error.log warn;
	access_log /var/www/nginx/log/$service_name-access.log main;

	index index.html;

	location / {
		try_files \$uri \$uri.html \$uri/ \$uri/index.html =404;
	}

	error_page 404 /404.html;
	location = /404.html {
		internal;
	}

	error_page 500 502 503 504 /50x.html;
	location = /50x.html {
		internal;
	}

	location ~ /\. {
		deny all;
	}
}

server {
	server_name www.$server_name;
	return 301 \$scheme://$server_name\$request_uri;
}
END
			# Create sample HTML files
			cat > "/var/www/nginx/sites/$service_name/public/index.html" <<END
<!DOCTYPE html>
<html>
<head>
	<title>Welcome to $server_name</title>
	<style>
		body { font-family: Arial, sans-serif; line-height: 1.6; margin: 40px auto; max-width: 650px; padding: 0 10px; }
	</style>
</head>
<body>
	<h1>Welcome to $server_name</h1>
	<p>This is a sample static page. Replace this content with your own HTML files.</p>
</body>
</html>
END

			cat > "/var/www/nginx/sites/$service_name/public/404.html" <<END
<!DOCTYPE html>
<html>
<head>
	<title>404 - Page Not Found</title>
	<style>
		body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
		h1 { color: #f0ad4e; }
	</style>
</head>
<body>
	<h1>404 - Page Not Found</h1>
	<p>The page you are looking for does not exist.</p>
</body>
</html>
END
		else
			# Proxy to backend (existing port or dotnet)
			proxy_target=""
			if [ "$create_dotnet_service" = true ]; then
				proxy_target="http://127.0.0.1:$internal_port"
			else
				proxy_target="$internal_address"
			fi
			
			cat > "/var/www/nginx/conf.d/$service_name.conf" <<END
server {
	client_max_body_size 200M;
	listen 80;
	server_name $server_name;
	root /usr/share/nginx/html;
	error_log /var/www/nginx/log/$service_name-error.log warn;
	access_log /var/www/nginx/log/$service_name-access.log main;

	location / {
		proxy_pass $proxy_target;
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
	}

	error_page 404 /404.html;
	location = /40x.html {
	}
	error_page 500 502 503 504 /50x.html;
	location = /50x.html {
	}
}

server {
	server_name www.$server_name;
	return 301 \$scheme://$server_name\$request_uri;
}
END
		fi
	else
	# Port-based configuration (no domain)
	if [ "$is_static" = true ]; then
		# Static HTML site with port
		cat > "/var/www/nginx/conf.d/$service_name-port.conf" <<END
server {
	client_max_body_size 200M;
	listen $external_port;
	server_name _;
	root /var/www/nginx/sites/$service_name/public;
	
	error_log /var/www/nginx/log/$service_name-error.log warn;
	access_log /var/www/nginx/log/$service_name-access.log main;

	index index.html;

	location / {
		try_files \$uri \$uri.html \$uri/ \$uri/index.html =404;
	}

	error_page 404 /404.html;
	location = /404.html {
		internal;
	}

	error_page 500 502 503 504 /50x.html;
	location = /50x.html {
		internal;
	}

	location ~ /\. {
		deny all;
	}
}
END
		# Create sample HTML files
		cat > "/var/www/nginx/sites/$service_name/public/index.html" <<END
<!DOCTYPE html>
<html>
<head>
	<title>Welcome to $service_name</title>
	<style>
		body { font-family: Arial, sans-serif; line-height: 1.6; margin: 40px auto; max-width: 650px; padding: 0 10px; }
	</style>
</head>
<body>
	<h1>Welcome to $service_name</h1>
	<p>This is a sample static page on port $external_port. Replace this content with your own HTML files.</p>
</body>
</html>
END

		cat > "/var/www/nginx/sites/$service_name/public/404.html" <<END
<!DOCTYPE html>
<html>
<head>
	<title>404 - Page Not Found</title>
	<style>
		body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
		h1 { color: #f0ad4e; }
	</style>
</head>
<body>
	<h1>404 - Page Not Found</h1>
	<p>The page you are looking for does not exist.</p>
</body>
</html>
END
	else
		# Proxy to backend (existing port or dotnet)
		proxy_target=""
		if [ "$create_dotnet_service" = true ]; then
			proxy_target="http://127.0.0.1:$internal_port"
		else
			proxy_target="$internal_address"
		fi
		
		cat > "/var/www/nginx/conf.d/$service_name-port.conf" <<END
server {
	client_max_body_size 200M;
	listen $external_port;
	server_name _;
	
	error_log /var/www/nginx/log/$service_name-error.log warn;
	access_log /var/www/nginx/log/$service_name-access.log main;

	location / {
		proxy_pass $proxy_target;
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
	}

	error_page 404 /404.html;
	location = /40x.html {
	}
	error_page 500 502 503 504 /50x.html;
	location = /50x.html {
	}
}
END
	fi
	# Open firewall port
	ufw allow $external_port/tcp
fi
	
	# Create dotnet service if needed
	if [ "$create_dotnet_service" = true ]; then
		echo "Creating .NET Core service..."
		mkdir -p /var/www/services
		chmod 777 /var/www/services
		
		cat > "/var/www/services/$service_name.service" <<END
[Unit]
Description=$service_name

[Service]
WorkingDirectory=/var/www/nginx/sites/$service_name/public
ExecStart=/usr/bin/dotnet /var/www/nginx/sites/$service_name/public/$dll_name.dll
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=$service_name
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
Environment=ASPNETCORE_HTTP_PORT=$internal_port
Environment=ASPNETCORE_URLS=http://localhost:$internal_port

[Install]
WantedBy=multi-user.target
END

		# Download sample site
		echo "Downloading sample .NET site..."
		wget nsknet.github.io/SampleBlankSite.tar -P /var/www/nginx/sites/$service_name/public/
		tar -xvf /var/www/nginx/sites/$service_name/public/SampleBlankSite.tar -C /var/www/nginx/sites/$service_name/public
		rm -fv /var/www/nginx/sites/$service_name/public/SampleBlankSite.tar
		
		# Rename sample files to match dll name
		mv /var/www/nginx/sites/$service_name/public/SampleBlankSite.deps.json /var/www/nginx/sites/$service_name/public/$dll_name.deps.json
		mv /var/www/nginx/sites/$service_name/public/SampleBlankSite /var/www/nginx/sites/$service_name/public/$dll_name
		mv /var/www/nginx/sites/$service_name/public/SampleBlankSite.pdb /var/www/nginx/sites/$service_name/public/$dll_name.pdb
		mv /var/www/nginx/sites/$service_name/public/SampleBlankSite.dll /var/www/nginx/sites/$service_name/public/$dll_name.dll
		mv /var/www/nginx/sites/$service_name/public/SampleBlankSite.runtimeconfig.json /var/www/nginx/sites/$service_name/public/$dll_name.runtimeconfig.json
		sed -i.bak s/SampleBlankSite/$dll_name/g /var/www/nginx/sites/$service_name/public/$dll_name.deps.json
		
		# Enable and start service
		systemctl daemon-reload
		systemctl enable /var/www/services/$service_name.service
		service $service_name start
	fi
	
	# Restart nginx
	systemctl restart nginx
	
	# Print summary
	echo ""
	echo "========================================================================="
	echo "✓ Nginx Site Configuration Complete!"
	echo "========================================================================="
	echo "Service name: $service_name"
	
	if [ "$use_domain" = true ]; then
		echo "Access URL: http://$server_name"
		echo "Domain: $server_name"
	else
		echo "Access URL: http://YOUR_SERVER_IP:$external_port"
		echo "External port: $external_port"
		echo ""
		echo "💡 Tip: You can use cloudflared or similar tools to tunnel:"
		echo "   cloudflared tunnel --url http://localhost:$external_port"
	fi
	
	echo ""
	if [ "$is_static" = true ]; then
		echo "Backend: Static HTML files"
		echo "Upload your files to: /var/www/nginx/sites/$service_name/public"
	elif [ "$create_dotnet_service" = true ]; then
		echo "Backend: .NET Core service"
		echo "Internal port: $internal_port"
		echo "Upload your code to: /var/www/nginx/sites/$service_name/public"
		echo "Main dll: $dll_name.dll"
		echo "Service config: /var/www/services/$service_name.service"
		echo ""
		echo "Service commands:"
		echo "  - Start: service $service_name start"
		echo "  - Stop: service $service_name stop"
		echo "  - Restart: service $service_name restart"
		echo "  - Status: service $service_name status"
	else
		echo "Backend: Existing service at $internal_address"
	fi
	
	echo ""
	echo "Nginx config: /var/www/nginx/conf.d/$service_name*.conf"
	echo "Logs: /var/www/nginx/log/$service_name-*.log"
	echo "========================================================================="
}


function install_nginx_php_domain(){
	echo "========================================================================="
	echo "Install new nginx domain and php site"
	printf "\nEnter your main domain [ENTER]: " 
	read server_name
	server_name_alias="www.$server_name"
	if [[ $server_name == *www* ]]; then
		server_name_alias=${server_name/www./''}
	fi


	mkdir -p /var/www/nginx/sites/$server_name/public
	# mkdir /var/www/nginx/sites/$server_name/private_html
	# mkdir /var/www/nginx/sites/$server_name/logs
	chmod 777 /var/www/nginx/sites/$server_name
	# chmod 777 /var/www/nginx/sites/$server_name/logs
	mkdir -p /var/log/nginx

	#take ownership to centos account
	# chown -R centos:centos /var/www/nginx/sites/$server_name
	chown -R nginx:nginx  /var/www/nginx/sites/$server_name


	cat > "/var/www/nginx/conf.d/$server_name.conf" <<END
server {
		client_max_body_size 200M;
		listen       80;
		server_name $server_name;
		#root         /usr/share/nginx/html;
		#root /var/www/$server_name/public; 
		root /var/www/nginx/sites/$server_name/public;
		error_log /var/www/nginx/log/$server_name-error.log;
		access_log  /var/www/nginx/log/$server_name-access.log main;
        	index index.php index.html index.htm index.nginx-debian.html;

		# Load configuration files for the default server block.
		include /etc/nginx/default.d/*.conf;

		location / {
			try_files \$uri \$uri/ /index.php\$request_uri;
		}

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:/var/run/php-fpm/php-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
		error_page 404 /404.html;
			location = /40x.html {
		}
		error_page 500 502 503 504 /50x.html;
			location = /50x.html {
		}
}
END

	cat > "/var/www/nginx/sites/$server_name/public/index.php" <<END
<?php
phpinfo();
?>
END

	sudo systemctl restart nginx

	echo "========================================================="
	echo "Domain added, please upload your code to: /var/www/nginx/sites/$server_name/public"
	echo "Domain name $server_name, nginx config at /var/www/nginx/conf.d/$server_name.conf"
	echo "If it thrown 403, please run this command: restorecon -r -v /var/www/nginx/sites/$server_name/public"
	echo "========================================================="

}
function install_wordpress_phpmyadmin(){
	echo "========================================================================="
	echo "Install Wordpress & phpMyAdmin"
	printf "\nEnter your main domain [ENTER]: " 
	read server_name
	server_name_alias="www.$server_name"
	if [[ $server_name == *www* ]]; then
		server_name_alias=${server_name/www./''}
	fi


	mkdir -p /var/www/nginx/sites/$server_name/public
	chmod 777 /var/www/nginx/sites/$server_name

	wget https://wordpress.org/latest.tar.gz
	wget https://files.phpmyadmin.net/phpMyAdmin/4.9.5/phpMyAdmin-4.9.5-english.tar.gz
	tar -zxvf latest.tar.gz
	tar -zxvf phpMyAdmin-4.9.5-english.tar.gz

	mv wordpress/* /var/www/nginx/sites/$server_name/public

	yes | cp -rf  wordpress/* /var/www/nginx/sites/$server_name/public
	rm -rf wordpress

	mkdir /var/www/nginx/sites/$server_name/public/phpMyAdmin
	mkdir /var/www/nginx/sites/$server_name/public/phpMyAdmin/tmp
	chmod 777 /var/www/nginx/sites/$server_name/public/phpMyAdmin/tmp
	yes | cp -rf  phpMyAdmin-4.9.5-english/* /var/www/nginx/sites/$server_name/public/phpMyAdmin
	rm -rf phpMyAdmin-4.9.5-english

	rm -fv  latest.tar.gz
	rm -fv  phpMyAdmin-4.9.5-english.tar.gz
	chown -R nginx:nginx  /var/www/nginx/sites/$server_name


	echo "========================================================="
	echo "Wordpress & phpMyAdmin have been installed to /var/www/nginx/sites/$server_name/public"
	echo "Wordpress: $server_name"
	echo "phpMyAdmin: $server_name/phpMyAdmin"
	echo "========================================================="

}


function install_nginx_certbot_add_domain_direct_dns(){
	echo "========================================================================="
	echo "Setup https"
	printf "\nEnter your main domain [ENTER]: " 
	read server_name
	server_name_alias="www.$server_name"
	if [[ $server_name == *www* ]]; then
		server_name_alias=${server_name/www./''}
	fi
	certbot --nginx  --noninteractive  --agree-tos --register-unsafely-without-email -d $server_name_alias
	echo ""
	echo "Done"
	echo "========================================================================="
}

function install_nginx_certbot_add_domain_cloudflare(){
	yum -y install python3-pip
	pip3 install certbot-dns-cloudflare
	
	echo "========================================================================="
	echo "Setup https"
	printf "\nEnter your main domain [ENTER]: " 
	read server_name
	server_name_alias="www.$server_name"
	if [[ $server_name == *www* ]]; then
		server_name_alias=${server_name/www./''}
	fi
	#didnt create /root/cloudflare.ini yet
	cat > "/var/www/services/$server_name.service"  <<END
[Unit]
dns_cloudflare_email = email@gmail.com
dns_cloudflare_api_key = Global API Key
END
	
	chmod 600 /root/cloudflare.ini
	certbot --dns-cloudflare --dns-cloudflare-credentials /root/cloudflare.ini --nginx  --noninteractive  --agree-tos --register-unsafely-without-email -d $server_name_alias -d *.$server_name_alias
	echo ""
	echo "Done"
	echo "========================================================================="
}


function install_mariadb(){
	echo "========================================================================="
	echo "Install MariaDB"

	sudo yum -y install mariadb-server
	sudo systemctl start mariadb.service
	sudo systemctl enable mariadb.service
	sudo systemctl status mariadb  --no-pager
	sudo mysql_secure_installation
	
	echo ""
	echo "Done"
	echo "========================================================================="
}

function install_open_vpn(){
	echo "========================================================================="
	echo "Install OpenVPN"
	curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
	chmod +x openvpn-install.sh
	AUTO_INSTALL=y ./openvpn-install.sh
	echo "Done"
	echo "========================================================================="
}

function install_virtual_ram_4g(){
	echo "========================================================================="
	echo "Add more 4GB Virtual RAM"
	sudo dd if=/dev/zero of=/swapfile bs=1024 count=4096k
	mkswap /swapfile
	swapon /swapfile
	swapon -s
	echo /swapfile none swap defaults 0 0 >> /etc/fstab
	chown root:root /swapfile 
	chmod 0600 /swapfile
	cat /proc/sys/vm/swappiness

	echo "Done"
	echo "========================================================================="

}

function common_configs(){
	echo "========================================================================="
	echo "Common config"

	echo "Set datetime to GMT+7"
	rm -f /etc/localtime
	ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
	
	echo "Common tools"
	apt update
	apt -y install wget axel htop tmux rar unrar bpytop ncdu

	#cloudflared
	wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
	sudo dpkg -i cloudflared-linux-amd64.deb
	cloudflared --version
	rm -f cloudflared-linux-amd64.deb
	

	echo "Firewall"
	apt install -y ufw	
	ufw default deny incoming
	ufw default allow outgoing
	ufw allow ssh
	ufw --force enable

	echo ""
	echo "Done"
	echo "========================================================================="
}

# Define an array for menu options
menu_options=(
    "Setup: Common config for all VPS (time zone, firewall, utils)"
    "Setup: Virtual RAM 4GB"
    "Install: .NET SDK 6, 7, 8, 9"
    "Install: NGINX"
    "Install: PostgreSql 12"
    "Install: MongoDB"
    "Install: Elasticsearch & Kibana"
    "Add: Nginx Site (Domain/Port + Static/Proxy/.NET)"
    "Deploy: Wordpress & phpMyAdmin"
)

# Function to display menu
function display_menu() {
    echo "Select function to execute or press CTRL+C to exit:"
    for i in "${!menu_options[@]}"; do
        printf "%3d) %s\n" $i "${menu_options[$i]}"
    done
}

# Function to execute selected option
function execute_option() {
    case $1 in
        0) common_configs ;;
        1) install_virtual_ram_4g ;;
        2) install_netcore ;;
        3) install_nginx ;;
        4) install_postgres_remote ;;
        5) install_mongodb ;;
        6) install_elastic_kibana ;;
        7) add_nginx_site ;;
        8) install_wordpress_phpmyadmin ;;
        *) echo "Invalid option" ;;
    esac
}

# Main menu loop
function main_menu() {
    while true; do
        echo "========================================================================="
        display_menu
        echo "========================================================================="
        read -p "Enter your choices (comma-separated, e.g., 9,8,7): " choices
        
        IFS=',' read -ra selected_options <<< "$choices"
        for option in "${selected_options[@]}"; do
            option=$(echo $option | tr -d ' ')  # Remove any whitespace
            if [[ $option =~ ^[0-9]+$ ]] && [ $option -ge 0 ] && [ $option -lt ${#menu_options[@]} ]; then
                echo "Executing: ${menu_options[$option]}"
                execute_option $option
                echo "========================================================================="
            else
                echo "Invalid option: $option"
            fi
        done
        
        read -p "Press Enter to continue or type 'q' to quit: " quit
        [[ $quit == "q" ]] && break
    done
}

# Call the main menu function
main_menu


#FAQ:

#Q: Wordpress: To perform the requested action, WordPress needs to access your web server
#A: Add this line to wp-config.php:
#	define( 'FS_METHOD', 'direct' );





