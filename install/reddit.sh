#!/bin/bash
###############################################################################
# reddit dev environment installer
# --------------------------------
# This script installs a reddit stack suitable for development. DO NOT run this
# on a system that you use for other purposes as it might delete important
# files, truncate your databases, and otherwise do mean things to you.
#
# By default, this script will install the reddit code in the current user's
# home directory and all of its dependencies (including libraries and database
# servers) at the system level. The installed reddit will expect to be visited
# on the domain "reddit.local" unless specified otherwise.  Configuring name
# resolution for the domain is expected to be done outside the installed
# environment (e.g. in your host machine's /etc/hosts file) and is not
# something this script handles.
#
# Several configuration options (listed in the "Configuration" section below)
# are overridable with environment variables. e.g.
#
#    sudo REDDIT_DOMAIN=example.com ./install/reddit.sh
#
###############################################################################

# load configuration
RUNDIR=$(dirname $0)
source $RUNDIR/install.cfg


###############################################################################
# Sanity Checks
###############################################################################
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must be run with root privileges."
    exit 1
fi

if [[ -z "$REDDIT_USER" ]]; then
    # in a production install, you'd want the code to be owned by root and run
    # by a less privileged user. this script is intended to build a development
    # install, so we expect the owner to run the app and not be root.
    cat <<END
ERROR: You have not specified a user. This usually means you're running this
script directly as root. It is not recommended to run reddit as the root user.

Please create a user to run reddit and set the REDDIT_USER variable
appropriately.
END
    exit 1
fi

if [[ "amd64" != $(dpkg --print-architecture) ]]; then
    cat <<END
ERROR: This host is running the $(dpkg --print-architecture) architecture!

Because of the pre-built dependencies in our PPA, and some extra picky things
like ID generation in liveupdate, installing reddit is only supported on amd64
architectures.
END
    exit 1
fi

# seriously! these checks are here for a reason. the packages from the
# reddit ppa aren't built for anything but trusty (14.04) right now, so
# if you try and use this install script on another release you're gonna
# have a bad time.
source /etc/lsb-release
if [ "$DISTRIB_ID" != "Ubuntu" -o "$DISTRIB_RELEASE" != "14.04" ]; then
    echo "ERROR: Only Ubuntu 14.04 is supported."
    exit 1
fi

if [[ "2000000" -gt $(awk '/MemTotal/{print $2}' /proc/meminfo) ]]; then
    LOW_MEM_PROMPT="reddit requires at least 2GB of memory to work properly, continue anyway? [y/n] "
    read -er -n1 -p "$LOW_MEM_PROMPT" response
    if [[ "$response" != "y" ]]; then
      echo "Quitting."
      exit 1
    fi
fi

###############################################################################
# Install prerequisites
###############################################################################

# install primary packages
$RUNDIR/install_apt.sh

# install cassandra from datastax
$RUNDIR/install_cassandra.sh

# install zookeeper
$RUNDIR/install_zookeeper.sh

# install services (rabbitmq, postgres, memcached, etc.)
$RUNDIR/install_services.sh

###############################################################################
# Install the reddit source repositories
###############################################################################
if [ ! -d $REDDIT_SRC ]; then
    mkdir -p $REDDIT_SRC
    chown $REDDIT_USER $REDDIT_SRC
fi

function copy_upstart {
    if [ -d ${1}/upstart ]; then
        cp ${1}/upstart/* /etc/init/
    fi
}

function clone_reddit_repo {
    local destination=$REDDIT_SRC/${1}
    local repository_url=https://github.com/${2}.git

    if [ ! -d $destination ]; then
        sudo -u $REDDIT_USER -H git clone $repository_url $destination
    fi

    copy_upstart $destination
}

function clone_reddit_service_repo {
    clone_reddit_repo $1 reddit/reddit-service-$1
}

clone_reddit_repo rbeer.trade abakedapplepie/rbeer.trade
clone_reddit_repo i18n reddit/reddit-i18n
clone_reddit_service_repo websockets
clone_reddit_service_repo activity
clone_reddit_repo gold reddit/reddit-plugin-gold
clone_reddit_repo about reddit/reddit-plugin-about


REDDIT_AVAILABLE_PLUGINS=""
for plugin in $REDDIT_PLUGINS; do
    if [ -d $REDDIT_SRC/$plugin ]; then
        if [[ -z "$REDDIT_PLUGINS" ]]; then
            REDDIT_AVAILABLE_PLUGINS+="$plugin"
        else
            REDDIT_AVAILABLE_PLUGINS+=" $plugin"
        fi
        echo "plugin $plugin found"
    else
        echo "plugin $plugin not found"
    fi
done

###############################################################################
# Configure Services
###############################################################################

# Configure Cassandra
$RUNDIR/setup_cassandra.sh

# Configure PostgreSQL
$RUNDIR/setup_postgres.sh

# Configure mcrouter
$RUNDIR/setup_mcrouter.sh

# Configure RabbitMQ
$RUNDIR/setup_rabbitmq.sh

###############################################################################
# Install and configure the reddit code
###############################################################################
function install_reddit_repo {
    pushd $REDDIT_SRC/$1
    sudo -u $REDDIT_USER python setup.py build
    python setup.py develop --no-deps
    popd
}

install_reddit_repo rbeer.trade/r2
install_reddit_repo i18n
for plugin in $REDDIT_AVAILABLE_PLUGINS; do
    copy_upstart $REDDIT_SRC/$plugin
    install_reddit_repo $plugin
done
install_reddit_repo websockets
install_reddit_repo activity

# generate binary translation files from source
sudo -u $REDDIT_USER make -C $REDDIT_SRC/i18n clean all

# this builds static files and should be run *after* languages are installed
# so that the proper language-specific static files can be generated and after
# plugins are installed so all the static files are available.
pushd $REDDIT_SRC/rbeer.trade/r2
sudo -u $REDDIT_USER make clean pyx

plugin_str=$(echo -n "$REDDIT_AVAILABLE_PLUGINS" | tr " " ,)
if [ ! -f development.update ]; then
    cat > development.update <<DEVELOPMENT
[DEFAULT]
# global debug flag -- displays pylons stacktrace rather than 500 page on error when true
# WARNING: a pylons stacktrace allows remote code execution. Make sure this is false
# if your server is publicly accessible.

debug = false
short_description = oh god how did this get here i am not good with computer

domain = $REDDIT_DOMAIN
oauth_domain = $REDDIT_DOMAIN

plugins = $plugin_str

media_provider = filesystem
media_fs_root = /srv/www/media
media_fs_base_url_http = http://%(domain)s/media/

default_header_url = rbeer.trade.header.png
https_endpoint = https://rbeer.trade
payment_domain = https://pay.rbeer.trade/
ad_domain = https://rbeer.trade
min_membership_create_community = 0
# s3_media_direct = false #??? default true


#### Accounts and Subreddits
# the user used for "system" operations and private messages
# system_user = spaz
# admins = spaz, rbeertrade
# the default subreddit for submissions
# default_sr = general
# account used for default feedback messaging (can be /r/subreddit)
# admin_message_acct = /r/Site_Issues
# subreddit used for trending subreddits postings. Ignored if blank.
# trending_sr = beertrade, beer
# list of subreddits to always include in a user's front page (unless they unsubscribe)
# automatic_reddits = Site_Issues, general
# subreddits that have subscribers hidden
hide_subscribers_srs = Site_Issues, general
# subreddit to use for beta testing
# beta_sr = beta
# name of the promos subreddit.
# promo_sr_name = promos
#### Analytics
# image to render to track pageviews
tracker_url = /pixel/of_destiny.png
# image to render to track HTTPS cert compatibility (needs to be protocol-relative)
httpstracker_url = https://rbeer.trade/static/mailgray.png
# url to request to track interaction statistics
uitracker_url = /pixel/of_discovery.png
# embeds pixel tracking url
eventtracker_url = /pixel/of_delight.png
anon_eventtracker_url = /pixel/of_diversity.png
# google analytics token
googleanalytics =
# google analytics events sampling rate. Valid values are 1-100.
# See https://developers.google.com/analytics/devguides/collection/gajs/methods/gaJSApiBasicConfiguration#_gat.GA_Tracker_._setSampleRate
googleanalytics_sample_rate = 50
# google analytics token for gold
googleanalytics_gold =
# google analytics events sampling rate for gold. Valid values are 1-100.
googleanalytics_sample_rate_gold = 1
# secret used for signing information on the above tracking pixels
tracking_secret = 3gvo48y6nv9b34t9n8436bw2x3945b43nw7n
# google tag manager container id
googletagmanager =
#### Wiki Pages
wiki_page_content_policy = contentpolicy
wiki_page_privacy_policy = privacypolicy
wiki_page_user_agreement = useragreement
wiki_page_registration_info = registration_info
wiki_page_gold_bottlecaps = gold_bottlecaps
wiki_page_stylesheets_everywhere =
#### ads
az_selfserve_priorities = 0
az_selfserve_network_id = 0
#### Feature toggles
disable_ads = true
disable_captcha = false
disable_ratelimit = false
disable_require_admin_otp = true
disable_wiki = false

[server:main]
port = 8001

# the following configuration section makes up the "live" config. if zookeeper
# is enabled, then this configuration will be found by the app in zookeeper. to
# write it to zookeeper, use the writer script: scripts/write_live_config.
[live_config]
# permissions! each user should have one of admin, sponsor, or employee as their permission level
# employees = rbeertrade:admin, spaz:admin
# a message placed in the infobar
announcement_message =
# an info message placed in the sidebar
sidebar_message =
# probability of the subreddit suggester showing up in the spotlight box
# for users that have at some point edited their subscriptions:
spotlight_interest_sub_p = 0
# and for users that have not ever subscribed:
spotlight_interest_nosub_p = 0
# messages to display in the "you're new here" welcome bar
# space-delimited list of strings with / to indicate newlines
welcomebar_messages =
# subreddit showcasing new multireddits
listing_chooser_explore_sr =
# subreddits that help people discover more subreddits (used in explore tab)
discovery_srs =
# historical cost to run a reddit server
pennies_per_server_second = 1970/1/1:1
# Controversial item determination
# Criteria for an item to meet to be determined as controversial
cflag_min_votes = 7
cflag_lower_bound = 0.4
cflag_upper_bound = 0.6
# Karma requirements to disable captchas - must meet at least one
captcha_exempt_link_karma = 1
captcha_exempt_comment_karma = 1
# Requirements to allow creating a subreddit - must meet age req + at least one karma req
create_sr_account_age_days = 0
create_sr_link_karma = 0
create_sr_comment_karma = 0
# Pages that are not yet supported by mobile web, and therefore should not
# receive the switch-to-mobile banner
mweb_blacklist_expressions = ^/prefs/?, ^/live/?, /message/, /wiki/?, /m/, ^/subreddits/create, /submit, ^/r/[^/]+/about/, ^/gold, ^/advertising, ^/promoted, ^/rules, ^/buttons
ads_popularity_threshold = 0
# Ads: determines probability to try to show ad for logged in user
ad_probability = 0

## HTTPS
# Used to gradually redirect users to HTTPS (without HSTS or secure cookies)
feature_https_redirect = on
# Force the use of HTTPS (tell apps we want HTTPS connections only, use `Secure` cookies)
# effectively means `https_redirect = on` as well.
feature_force_https = on
# Take existing cookies and make them HTTPS-only (requires `force_https`)
feature_upgrade_cookies = on
DEVELOPMENT
    chown $REDDIT_USER development.update
else
    sed -i "s/^plugins = .*$/plugins = $plugin_str/" $REDDIT_SRC/rbeer.trade/r2/development.update
    sed -i "s/^domain = .*$/domain = $REDDIT_DOMAIN/" $REDDIT_SRC/rbeer.trade/r2/development.update
    sed -i "s/^oauth_domain = .*$/oauth_domain = $REDDIT_DOMAIN/" $REDDIT_SRC/rbeer.trade/r2/development.update
fi

sudo -u $REDDIT_USER make ini

if [ ! -L run.ini ]; then
    sudo -u $REDDIT_USER ln -nsf development.ini run.ini
fi

popd

###############################################################################
# some useful helper scripts
###############################################################################
function helper-script() {
    cat > $1
    chmod 755 $1
}

helper-script /usr/local/bin/reddit-run <<REDDITRUN
#!/bin/bash
exec paster --plugin=r2 run $REDDIT_SRC/rbeer.trade/r2/run.ini "\$@"
REDDITRUN

helper-script /usr/local/bin/reddit-shell <<REDDITSHELL
#!/bin/bash
exec paster --plugin=r2 shell $REDDIT_SRC/rbeer.trade/r2/run.ini
REDDITSHELL

helper-script /usr/local/bin/reddit-start <<REDDITSTART
#!/bin/bash
initctl emit reddit-start
REDDITSTART

helper-script /usr/local/bin/reddit-stop <<REDDITSTOP
#!/bin/bash
initctl emit reddit-stop
REDDITSTOP

helper-script /usr/local/bin/reddit-restart <<REDDITRESTART
#!/bin/bash
initctl emit reddit-restart TARGET=${1:-all}
REDDITRESTART

helper-script /usr/local/bin/reddit-flush <<REDDITFLUSH
#!/bin/bash
echo flush_all | nc localhost 11211
REDDITFLUSH

helper-script /usr/local/bin/reddit-serve <<REDDITSERVE
#!/bin/bash
exec paster serve --reload $REDDIT_SRC/rbeer.trade/r2/run.ini
REDDITSERVE

###############################################################################
# pixel and click server
###############################################################################
mkdir -p /var/opt/reddit/
chown $REDDIT_USER:$REDDIT_GROUP /var/opt/reddit/

mkdir -p /srv/www/pixel
chown $REDDIT_USER:$REDDIT_GROUP /srv/www/pixel
cp $REDDIT_SRC/rbeer.trade/r2/r2/public/static/pixel.png /srv/www/pixel

if [ ! -f /etc/gunicorn.d/click.conf ]; then
    cat > /etc/gunicorn.d/click.conf <<CLICK
CONFIG = {
    "mode": "wsgi",
    "working_dir": "$REDDIT_SRC/rbeer.trade/scripts",
    "user": "$REDDIT_USER",
    "group": "$REDDIT_USER",
    "args": (
        "--bind=unix:/var/opt/rbeer.trade/click.sock",
        "--workers=1",
        "tracker:application",
    ),
}
CLICK
fi

service gunicorn start

###############################################################################
# nginx
###############################################################################



###############################################################################
# Setup lets encrypt?!
###############################################################################
service haproxy stop
certbot certonly --standalone -n --agree-tos -m rbeertrade@rbeer.trade -d www.$REDDIT_DOMAIN -d $REDDIT_DOMAIN


mkdir -p /srv/www/media
chown $REDDIT_USER:$REDDIT_GROUP /srv/www/media

cat > /etc/nginx/sites-available/reddit-media <<MEDIA
server {
    listen 9000;

    expires max;

    location /media/ {
        alias /srv/www/media/;
    }
}
MEDIA

cat > /etc/nginx/sites-available/reddit-pixel <<PIXEL
upstream click_server {
  server unix:/var/opt/reddit/click.sock fail_timeout=0;
}

server {
  listen 8082;

  log_format directlog '\$remote_addr - \$remote_user [\$time_local] '
                      '"\$request_method \$request_uri \$server_protocol" \$status \$body_bytes_sent '
                      '"\$http_referer" "\$http_user_agent"';
  access_log      /var/log/nginx/traffic/traffic.log directlog;

  location / {

    rewrite ^/pixel/of_ /pixel.png;

    add_header Last-Modified "";
    add_header Pragma "no-cache";

    expires -1;
    root /srv/www/pixel/;
  }

  location /click {
    proxy_pass http://click_server;
  }
}
PIXEL

cat > /etc/nginx/sites-available/reddit-ssl <<SSL
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

server {
    listen 443;

    ssl on;
    ssl_certificate /etc/letsencrypt/live/www.rbeer.trade/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/www.rbeer.trade/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/www.rbeer.trade/fullchain.pem;
    server_name rbeer.trade www.rbeer.trade;

    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;

    ssl_session_cache shared:SSL:1m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$http_host;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_pass_header Server;
        
        #no idea if this is even doing anything
        add_header Access-Control-Allow-Origin *;

        # allow websockets through if desired
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
SSL

# remove the default nginx site that may conflict with haproxy
rm -rf /etc/nginx/sites-enabled/default
# put our config in place
ln -nsf /etc/nginx/sites-available/reddit-media /etc/nginx/sites-enabled/
ln -nsf /etc/nginx/sites-available/reddit-pixel /etc/nginx/sites-enabled/
ln -nsf /etc/nginx/sites-available/reddit-ssl /etc/nginx/sites-enabled/

# make the pixel log directory
mkdir -p /var/log/nginx/traffic

# link the ini file for the Flask click tracker
ln -nsf $REDDIT_SRC/rbeer.trade/r2/development.ini $REDDIT_SRC/rbeer.trade/scripts/production.ini

service nginx restart

###############################################################################
# haproxy
###############################################################################
if [ -e /etc/haproxy/haproxy.cfg ]; then
    BACKUP_HAPROXY=$(mktemp /etc/haproxy/haproxy.cfg.XXX)
    echo "Backing up /etc/haproxy/haproxy.cfg to $BACKUP_HAPROXY"
    cat /etc/haproxy/haproxy.cfg > $BACKUP_HAPROXY
fi

# make sure haproxy is enabled
cat > /etc/default/haproxy <<DEFAULT
ENABLED=1
DEFAULT

# configure haproxy
cat > /etc/haproxy/haproxy.cfg <<HAPROXY
global
    maxconn 350

frontend frontend
    mode http

    bind 0.0.0.0:80
    bind 127.0.0.1:8080

    timeout client 24h
    option forwardfor except 127.0.0.1
    option httpclose

    # make sure that requests have x-forwarded-proto: https iff tls
    reqidel ^X-Forwarded-Proto:.*
    acl is-ssl dst_port 8080
    reqadd X-Forwarded-Proto:\ https if is-ssl

    # send websockets to the websocket service
    acl is-websocket hdr(Upgrade) -i WebSocket
    use_backend websockets if is-websocket

    # send media stuff to the local nginx
    acl is-media path_beg /media/
    use_backend media if is-media

    # send pixel stuff to local nginx
    acl is-pixel path_beg /pixel/
    acl is-click path_beg /click
    use_backend pixel if is-pixel || is-click

    default_backend reddit

backend reddit
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server app01-8001 localhost:8001 maxconn 30

backend websockets
    mode http
    timeout connect 4s
    timeout server 24h
    balance roundrobin

    server websockets localhost:9001 maxconn 250

backend media
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server nginx localhost:9000 maxconn 20

backend pixel
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server nginx localhost:8082 maxconn 20
HAPROXY

# this will start it even if currently stopped
service haproxy restart

###############################################################################
# websocket service
###############################################################################

if [ ! -f /etc/init/reddit-websockets.conf ]; then
    cat > /etc/init/reddit-websockets.conf << UPSTART_WEBSOCKETS
description "websockets service"

stop on runlevel [!2345] or reddit-restart all or reddit-restart websockets
start on runlevel [2345] or reddit-restart all or reddit-restart websockets

respawn
respawn limit 10 5
kill timeout 15

limit nofile 65535 65535

exec baseplate-serve2 --bind localhost:9001 $REDDIT_SRC/websockets/example.ini
UPSTART_WEBSOCKETS
fi

service reddit-websockets restart

###############################################################################
# activity service
###############################################################################

if [ ! -f /etc/init/reddit-activity.conf ]; then
    cat > /etc/init/reddit-activity.conf << UPSTART_ACTIVITY
description "activity service"

stop on runlevel [!2345] or reddit-restart all or reddit-restart activity
start on runlevel [2345] or reddit-restart all or reddit-restart activity

respawn
respawn limit 10 5
kill timeout 15

exec baseplate-serve2 --bind localhost:9002 $REDDIT_SRC/activity/example.ini
UPSTART_ACTIVITY
fi

service reddit-activity restart

###############################################################################
# geoip service
###############################################################################
if [ ! -f /etc/gunicorn.d/geoip.conf ]; then
    cat > /etc/gunicorn.d/geoip.conf <<GEOIP
CONFIG = {
    "mode": "wsgi",
    "working_dir": "$REDDIT_SRC/rbeer.trade/scripts",
    "user": "$REDDIT_USER",
    "group": "$REDDIT_USER",
    "args": (
        "--bind=127.0.0.1:5000",
        "--workers=1",
         "--limit-request-line=8190",
         "geoip_service:application",
    ),
}
GEOIP
fi

service gunicorn start

###############################################################################
# Job Environment
###############################################################################
CONSUMER_CONFIG_ROOT=$REDDIT_HOME/consumer-count.d

if [ ! -f /etc/default/reddit ]; then
    cat > /etc/default/reddit <<DEFAULT
export REDDIT_ROOT=$REDDIT_SRC/rbeer.trade/r2
export REDDIT_INI=$REDDIT_SRC/rbeer.trade/r2/run.ini
export REDDIT_USER=$REDDIT_USER
export REDDIT_GROUP=$REDDIT_GROUP
export REDDIT_CONSUMER_CONFIG=$CONSUMER_CONFIG_ROOT
alias wrap-job=$REDDIT_SRC/rbeer.trade/scripts/wrap-job
alias manage-consumers=$REDDIT_SRC/rbeer.trade/scripts/manage-consumers
DEFAULT
fi

###############################################################################
# Queue Processors
###############################################################################
mkdir -p $CONSUMER_CONFIG_ROOT

function set_consumer_count {
    if [ ! -f $CONSUMER_CONFIG_ROOT/$1 ]; then
        echo $2 > $CONSUMER_CONFIG_ROOT/$1
    fi
}

set_consumer_count search_q 0
set_consumer_count del_account_q 1
set_consumer_count scraper_q 1
set_consumer_count markread_q 1
set_consumer_count commentstree_q 1
set_consumer_count newcomments_q 1
set_consumer_count vote_link_q 1
set_consumer_count vote_comment_q 1
set_consumer_count automoderator_q 0
set_consumer_count butler_q 1
set_consumer_count author_query_q 1
set_consumer_count subreddit_query_q 1
set_consumer_count domain_query_q 1

chown -R $REDDIT_USER:$REDDIT_GROUP $CONSUMER_CONFIG_ROOT/

###############################################################################
# Complete plugin setup, if setup.sh exists
###############################################################################
for plugin in $REDDIT_AVAILABLE_PLUGINS; do
    if [ -x $REDDIT_SRC/$plugin/setup.sh ]; then
        echo "Found setup.sh for $plugin; running setup script"
        $REDDIT_SRC/$plugin/setup.sh $REDDIT_SRC $REDDIT_USER
    fi
done

###############################################################################
# Start everything up
###############################################################################

# the initial database setup should be done by one process rather than a bunch
# vying with eachother to get there first
reddit-run -c 'print "ok done"'

# ok, now start everything else up
initctl emit reddit-stop
initctl emit reddit-start

###############################################################################
# Cron Jobs
###############################################################################
if [ ! -f /etc/cron.d/reddit ]; then
    cat > /etc/cron.d/reddit <<CRON
0    3 * * * root /sbin/start --quiet reddit-job-update_sr_names
30  16 * * * root /sbin/start --quiet reddit-job-update_reddits
0    * * * * root /sbin/start --quiet reddit-job-update_promos
*/5  * * * * root /sbin/start --quiet reddit-job-clean_up_hardcache
*/2  * * * * root /sbin/start --quiet reddit-job-broken_things
*/2  * * * * root /sbin/start --quiet reddit-job-rising
0    * * * * root /sbin/start --quiet reddit-job-trylater

#letsencrypt
0    5 * * * root certbot renew --quiet --pre-hook "service haproxy stop" --post-hook "service haproxy start;service nginx restart"

# liveupdate
*    * * * * root /sbin/start --quiet reddit-job-liveupdate_activity

# jobs that recalculate time-limited listings (e.g. top this year)
PGPASSWORD=password
*/15 * * * * $REDDIT_USER $REDDIT_SRC/rbeer.trade/scripts/compute_time_listings link year "['hour', 'day', 'week', 'month', 'year']"
*/15 * * * * $REDDIT_USER $REDDIT_SRC/rbeer.trade/scripts/compute_time_listings comment year "['hour', 'day', 'week', 'month', 'year']"

# disabled by default, uncomment if you need these jobs
#*    * * * * root /sbin/start --quiet reddit-job-email
#0    0 * * * root /sbin/start --quiet reddit-job-update_gold_users
CRON
fi

###############################################################################
# Finished with install script
###############################################################################
# print this out here. if vagrant's involved, it's gonna do more steps
# afterwards and then re-run this script but that's ok.
$RUNDIR/done.sh
