auth_basic $auth_type;
# .htpasswd lives in a bind-mounted dir (coolify_storage: host <log_host_base>/staging/auth
# -> /var/www/auth). A directory mount, not a single-file mount — see infra storage.tf.
auth_basic_user_file /var/www/auth/.htpasswd;
