printf "\nEnter your domain name (sample.com): " 
read server_name

printf "\nEnter your real ip address (177.178.179.5): " 
read vps_ip


cat > "/var/www/nginx/conf.d/$server_name.conf" <<END

server {
    listen 80;
	server_name $server_name;
	error_log /var/www/nginx/log/$server_name-error.log;
	access_log  /var/www/nginx/log/$server_name-access.log main;

    location / {
      proxy_set_header        Host \$host;
      proxy_set_header        X-Real-IP \$remote_addr;
      proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header        X-Forwarded-Proto \$scheme;

      proxy_pass          http://$vps_ip:80;
      proxy_read_timeout  90;

      proxy_redirect      http://$vps_ip:80 http://$server_name;
    }
}
 
server {
    server_name www.$server_name;
    return 301 \$scheme://$server_name\$request_uri;
}
END

systemctl daemon-reload
service nginx restart 
service nginx status 