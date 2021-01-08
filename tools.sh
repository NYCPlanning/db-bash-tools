#!/bin/bash
function set_env {
  for envfile in $@
  do
    if [ -f $envfile ]
      then
        export $(cat $envfile | sed 's/#.*//g' | xargs)
      fi
  done
}

function urlparse {
    proto="$(echo $1 | grep :// | sed -e's,^\(.*://\).*,\1,g')"
    url=$(echo $1 | sed -e s,$proto,,g)
    userpass="$(echo $url | grep @ | cut -d@ -f1)"
    BUILD_PWD=`echo $userpass | grep : | cut -d: -f2`
    BUILD_USER=`echo $userpass | grep : | cut -d: -f1`
    hostport=$(echo $url | sed -e s,$userpass@,,g | cut -d/ -f1)
    BUILD_HOST="$(echo $hostport | sed -e 's,:.*,,g')"
    BUILD_PORT="$(echo $hostport | sed -e 's,^.*:,:,g' -e 's,.*:\([0-9]*\).*,\1,g' -e 's,[^0-9],,g')"
    BUILD_DB="$(echo $url | grep / | cut -d/ -f2-)"
}

function FGDB_export {
    mkdir -p output/$@.gdb &&
    (
        cd output/$@.gdb
        docker run \
        -v $(pwd):/data\
        --user $UID\
        --rm webmapp/gdal-docker:latest ogr2ogr -progress -f "FileGDB" $@.gdb \
            PG:"host=$BUILD_HOST user=$BUILD_USER port=$BUILD_PORT dbname=$BUILD_DB password=$BUILD_PWD" \
            -mapFieldType Integer64=Real\
            -lco GEOMETRY_NAME=Shape\
            -nln $@\
            -nlt MULTIPOLYGON $@
    )
}

function SHP_export {
    mkdir -p output/$@ &&
    (
        cd output/$@
        ogr2ogr -progress -f "ESRI Shapefile" $@.shp \
            PG:"host=$BUILD_HOST user=$BUILD_USER port=$BUILD_PORT dbname=$BUILD_DB password=$BUILD_PWD" \
            -nlt MULTIPOLYGON $@
        rm -f $@.zip
        zip $@.zip *
        ls | grep -v $@.zip | xargs rm
    )
}

function CSV_export {
  psql $BUILD_ENGINE  -c "\COPY (
    SELECT * FROM $@
  ) TO STDOUT DELIMITER ',' CSV HEADER;" > $@.csv
}

function imports_csv {
   cat data/$1.csv | psql $BUILD_ENGINE -c "COPY $1 FROM STDIN DELIMITER ',' CSV HEADER;"
}

function Upload {
  STATUS=$(mc stat --json spaces/edm-publishing/ceqr-app-data-staging/$1/$2 | jq -r '.status')
  case $STATUS in
    success) mc rm -r --force spaces/edm-publishing/ceqr-app-data-staging/$1/$2 ;;
    error) true ;;
  esac
  for file in output/*
  do
    name=$(basename $file)
    mc cp $file spaces/edm-publishing/ceqr-app-data-staging/$1/$2/$name
  done
  wait
}

function Publish {
  RECIPE=$1
  VERSION=${2:-latest}
  STAGING_PATH=spaces/edm-publishing/ceqr-app-data-staging/$1/$VERSION
  VERSION_NAME=$(mc cat $STAGING_PATH/version.txt)
  PUBLISH_PATH=spaces/edm-publishing/ceqr-app-data/$1/$VERSION_NAME
  PUBLISH_PATH_LATEST=spaces/edm-publishing/ceqr-app-data/$1/latest
  echo "
    publishing  ceqr-app-data-staging/$1/$VERSION_NAME 
    to          ceqr-app-data/$1/$VERSION_NAME
  "
  for INFO in $(mc ls --recursive --json $STAGING_PATH)
  do
    KEY=$(echo $INFO | jq -r '.key')
    EXT="${KEY#*.}"
    case $EXT in
      txt | zip | csv | pdf | csv.zip | shp.zip )
        mc cp $STAGING_PATH/$KEY /tmp/ceqr-app-data-staging/$1/$VERSION/$KEY
        STATUS=$(mc stat --json $PUBLISH_PATH/$KEY | jq -r '.status')
        case $STATUS in
          success) mc rm -r --force $PUBLISH_PATH/$KEY ;;
          error) true ;;
        esac
        # Copy to publish path
        mc cp /tmp/ceqr-app-data-staging/$1/$VERSION/$KEY $PUBLISH_PATH/$KEY
        # Promote to latest
        mc cp /tmp/ceqr-app-data-staging/$1/$VERSION/$KEY $PUBLISH_PATH_LATEST/$KEY
        rm -rf /tmp/ceqr-app-data-staging
      ;;
      *)
        echo "skipping $KEY"
      ;;
    esac
  done;
}

function List {
  if [[ "$2" == "production" ]]
  then
    echo "
    listing ceqr-app-data/$1
    "
    mc ls spaces/edm-publishing/ceqr-app-data/$1
  else
    echo "
    listing ceqr-app-data-staging/$1
    "
    mc ls spaces/edm-publishing/ceqr-app-data-staging/$1
  fi
}