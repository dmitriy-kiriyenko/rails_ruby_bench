set -e

# To be run as user "postgres"
createuser --createdb --superuser -Upostgres $(cat /tmp/username)
psql -c "ALTER USER $(cat /tmp/username) WITH PASSWORD 'password';"
psql -c "create database publify_development owner $(cat /tmp/username) encoding 'UTF8' TEMPLATE template0;"
psql -c "create database publify_test        owner $(cat /tmp/username) encoding 'UTF8' TEMPLATE template0;"
psql -d publify_development -c "CREATE EXTENSION hstore;"
psql -d publify_development -c "CREATE EXTENSION pg_trgm;"
exit
