# Included inside the server block (nginx.conf: include conf.d/*.inc). $auth_type
# is computed in basic-auth.conf: the realm string on gated hosts, "off" otherwise.
# nginx reads auth_basic_user_file lazily, so an "off" host never touches the file
# (safe even where the .htpasswd is not mounted, e.g. production).
auth_basic $auth_type;
# .htpasswd lives in a bind-mounted dir (coolify_storage: host <log_host_base>/<env>/auth
# -> /var/www/auth), provisioned where enable_basic_auth = true — see infra storage.tf.
auth_basic_user_file /var/www/auth/.htpasswd;
