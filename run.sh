#!/bin/bash

set -euo pipefail

CONFIG_BUNDLE_DIR="/usr/local/share/osm-tirex/config"

ensureConfigDefaults() {
    local config_file=""
    local source_file=""
    local target_file=""
    local index_file="/data/config/index.html"
    local default_files=(
        postgresql.custom.conf
        tirex.conf
        mapnik.conf
        region.conf
        tirex-region.conf
        index.html
    )

    mkdir -p /data/config

    for config_file in "${default_files[@]}"; do
        source_file="$CONFIG_BUNDLE_DIR/$config_file"
        target_file="/data/config/$config_file"

        if [ -f "$source_file" ] && [ ! -f "$target_file" ]; then
            cp "$source_file" "$target_file"
        fi
    done

    # Older config volumes may still contain the original demo page with the
    # literal placeholder host. Repair just that known-bad URL in place so we
    # don't overwrite any other local customizations.
    if [ -f "$index_file" ] && grep -Fq 'http://{IP or HOSTNAME}:8080/{z}/{x}/{y}.png' "$index_file"; then
        sed -i 's|http://{IP or HOSTNAME}:8080/{z}/{x}/{y}.png|/{z}/{x}/{y}.png|g' "$index_file"
    fi
}

sanitizeFlowerbedSvgAssets() {
    local style_dir="${1:-/data/style}"
    local asset=""
    local asset_path=""
    local -a flowerbed_svgs=(
        symbols/flowerbed_mid_zoom.svg
        symbols/flowerbed_high_zoom.svg
    )

    if [ ! -d "$style_dir" ]; then
        return 0
    fi

    for asset in "${flowerbed_svgs[@]}"; do
        asset_path="$style_dir/$asset"
        if [ -f "$asset_path" ] && grep -Eq 'clip-path=("none"|'"'"'none'"'"')|clipPath=("none"|'"'"'none'"'"')' "$asset_path" 2> /dev/null; then
            sed -i \
                -e 's/ clip-path="none"//g' \
                -e "s/ clip-path='none'//g" \
                -e 's/ clipPath="none"//g' \
                -e "s/ clipPath='none'//g" \
                "$asset_path"
            echo "INFO: Removed unsupported clip-path=none attribute from ${asset_path#$style_dir/}"
        fi
    done
}

diagnoseUnsupportedSvgAssets() {
    local style_dir="${1:-/data/style}"
    local mapnik_xml="$style_dir/mapnik.xml"
    local max_report=20
    local -a referenced_svgs=()
    local -a suspect_svgs=()
    local asset=""
    local asset_path=""
    local i=0

    if [ ! -d "$style_dir" ]; then
        return 0
    fi

    # Use the generated mapnik.xml as the source of truth for which SVG assets
    # are actually referenced by the CartoCSS/MML style at runtime. This avoids
    # reporting helper/source SVGs such as symbols/generating_patterns/*.svg that
    # may exist in the style tree but are not used directly by Mapnik.
    if [ ! -f "$mapnik_xml" ]; then
        echo "INFO: SVG diagnostic skipped because $mapnik_xml does not exist yet"
        return 0
    fi

    mapfile -t referenced_svgs < <(grep -Eo '[[:alnum:]_./-]+\.svg' "$mapnik_xml" | sort -u || true)

    if [ "${#referenced_svgs[@]}" -eq 0 ]; then
        echo "INFO: SVG diagnostic found no referenced SVG assets in $mapnik_xml"
        return 0
    fi

    for asset in "${referenced_svgs[@]}"; do
        asset="${asset#./}"
        if [ "${asset#/}" != "$asset" ]; then
            asset_path="$asset"
        else
            asset_path="$style_dir/$asset"
        fi

        if [ -f "$asset_path" ] && grep -Eq 'clip-path|clipPath' "$asset_path" 2> /dev/null; then
            if [ "${asset_path#$style_dir/}" != "$asset_path" ]; then
                suspect_svgs+=("${asset_path#$style_dir/}")
            else
                suspect_svgs+=("$asset")
            fi
        fi
    done

    if [ "${#suspect_svgs[@]}" -eq 0 ]; then
        echo "INFO: SVG diagnostic found no referenced style SVG assets using clip-path in $mapnik_xml"
        return 0
    fi

    echo "WARNING: SVG diagnostic found ${#suspect_svgs[@]} referenced style SVG asset(s) using clip-path/clipPath; these may trigger Mapnik SVG parsing warnings:"
    for (( i=0; i<${#suspect_svgs[@]} && i<max_report; i++ )); do
        echo "  - ${suspect_svgs[$i]}"
    done
    if [ "${#suspect_svgs[@]}" -gt "$max_report" ]; then
        echo "  - ... and $(( ${#suspect_svgs[@]} - max_report )) more"
    fi
}

cartoBuild() {
    # if there is no custom style mounted, then use osm-carto
    if [ ! "$(ls -A /data/style/)" ]; then
        cp -a /home/$USER/src/openstreetmap-carto-backup/* /data/style/
    fi
    ln -snf /data/style /home/$USER/src/openstreetmap-carto

    # carto build
    if [ ! -f /data/style/mapnik.xml ]; then
        cd /data/style/
        carto ${NAME_MML:-project.mml} > mapnik.xml
    fi

    # Patch font names in a pre-existing mapnik.xml that may have been generated
    # with variants unavailable on Ubuntu 24.04 (causes Mapnik load warnings or,
    # with strict font settings, outright failures).
    # Also strip host= and port= from PostGIS datasources so Mapnik connects via
    # Unix socket rather than TCP. TCP requires md5 password auth (pg_hba.conf
    # default), but the mapnik.xml generated by carto carries no password.
    # Unix socket connections use peer auth: OS user _tirex == PostgreSQL user _tirex.
    if [ -f /data/style/mapnik.xml ]; then
        sed -i \
            -e 's/Noto Sans Syriac Black/Noto Sans Syriac Regular/g' \
            -e 's/Noto Emoji Bold/Noto Emoji Regular/g' \
            /data/style/mapnik.xml
        # Delete lines that set host= or port= in any PostGIS datasource block.
        sed -i \
            -e '/<Parameter name="host">/d' \
            -e '/<Parameter name="port">/d' \
            /data/style/mapnik.xml
    fi

    # Mapnik logs warnings for the exact clip-path="none" attribute present in
    # the upstream flowerbed pattern SVGs even though the attribute has no
    # visual effect. Strip only that harmless attribute from just those two
    # files so users stop triggering the warnings while navigating the map.
    sanitizeFlowerbedSvgAssets /data/style
}

addDBConfig() {
    ln -snf /data/config/postgresql.custom.conf /etc/postgresql/$POSTGRESQL_VER/main/conf.d/postgresql.custom.conf
    # cat /etc/postgresql/$POSTGRESQL_VER/main/conf.d/postgresql.custom.conf

    if [ ! -d /data/database/postgres ]; then
        mv /var/lib/postgresql/$POSTGRESQL_VER/main /data/database/postgres
    else
        rm -fr /var/lib/postgresql/$POSTGRESQL_VER/main
    fi
    ln -snf /data/database/postgres /var/lib/postgresql/$POSTGRESQL_VER/main

    # Ensure that database directory is in right state
    chown $USER: /data/database/
    chown -R postgres: /var/lib/postgresql /data/database/postgres/
    if [ ! -f /data/database/postgres/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/$POSTGRESQL_VER/bin/pg_ctl -D /data/database/postgres/ initdb -o "--locale C.UTF-8"
    fi

    # Configure PosgtreSQL
    #   && echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/$POSTGRESQL_VER/main/pg_hba.conf \
    #   && echo "host all all ::/0 md5" >> /etc/postgresql/$POSTGRESQL_VER/main/pg_hba.conf
}

setupGisDB() {
    if [ ! "$( sudo -u postgres psql -XtAc "SELECT usename FROM pg_user WHERE usename='$USER'" )" ]; then
        sudo -u postgres createuser $USER
        if [ ! "$( sudo -u postgres psql -XtAc "SELECT 1 FROM pg_database WHERE datname='gis'" )" ]; then
            sudo -u postgres createdb -E UTF8 -O $USER gis
            sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
            sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
            sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO $USER;"
            sudo -u postgres psql -d gis -c "ALTER TABLE geography_columns OWNER TO $USER;"
            sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO $USER;"
            sudo -u postgres psql -c "ALTER USER $USER PASSWORD '${PGPASSWORD:-$USER}'"
        fi
    fi
}

setupTirex() {
    rm -fr /etc/tirex/renderer/test* /etc/tirex/renderer/mapnik/tirex-example.conf

    ln -snf /data/config/tirex.conf /etc/tirex/tirex.conf
    ln -snf /data/config/mapnik.conf /etc/tirex/renderer/mapnik.conf
    ln -snf /data/config/region.conf /etc/tirex/renderer/mapnik/region.conf

    rm -fr /var/cache/tirex/tiles && ln -snf /data/tiles /var/cache/tirex/tiles
    mkdir -p /data/tiles/region
    chown -R $USER: /data/tiles

    rm -fr /usr/share/tirex/region
    mkdir -p /usr/share/tirex/region

    mkdir -p /data/config/leaflet
    if [ ! -f /data/config/leaflet/leaflet.css ]; then
        cp /usr/local/share/osm-tirex/leaflet/leaflet.css /data/config/leaflet/leaflet.css
    fi
    if [ ! -f /data/config/leaflet/leaflet.min.js ]; then
        cp /usr/local/share/osm-tirex/leaflet/leaflet.min.js /data/config/leaflet/leaflet.min.js
    fi

    # Keep the bundled demo page working even if the distro package no longer
    # ships an example-map directory at this path.
    if [ -d /usr/share/tirex/example-map ]; then
        cp -a /usr/share/tirex/example-map/. /usr/share/tirex/region/
    fi

    # Some Ubuntu tirex-example-map packages install a file or symlink named
    # "leaflet" in this directory. Replace it with our own directory so the
    # bundled demo assets can always be linked consistently.
    rm -fr /usr/share/tirex/region/leaflet
    mkdir -p /usr/share/tirex/region/leaflet

    ln -snf /data/config/index.html /usr/share/tirex/region/index.html
    ln -snf /data/config/leaflet/leaflet.css /usr/share/tirex/region/leaflet/leaflet.css
    ln -snf /data/config/leaflet/leaflet.min.js /usr/share/tirex/region/leaflet/leaflet.min.js
    ln -snf /data/config/tirex-region.conf /etc/apache2/conf-available/tirex-region.conf

    if [ -f /etc/apache2/conf-available/tirex.conf ]; then
        a2disconf tirex
    fi
    if [ -f /etc/apache2/conf-available/tirex-example-map.conf ]; then
        a2disconf tirex-example-map
    fi
    a2enconf tirex-region

    # Some image-cleanup steps or derived images may leave Apache runtime/log
    # directories missing, which makes `service apache2 restart` fail its
    # config test even though the site configuration is otherwise valid.
    mkdir -p /var/log/apache2 /var/run/apache2 /var/lock/apache2
}

resolveImportStyleFile() {
    local requested="${NAME_STYLE:-}"

    if [ -n "$requested" ]; then
        if [ -f "/data/style/$requested" ]; then
            printf '%s\n' "$requested"
            return 0
        fi
        if [ "${requested#*/}" = "$requested" ] && [ -f "/data/style/style/$requested" ]; then
            printf 'style/%s\n' "$requested"
            return 0
        fi
        return 1
    fi

    if [ -f /data/style/openstreetmap-carto-flex.lua ]; then
        printf '%s\n' 'openstreetmap-carto-flex.lua'
        return 0
    fi
    if [ -f /data/style/style/openstreetmap-carto-flex.lua ]; then
        printf '%s\n' 'style/openstreetmap-carto-flex.lua'
        return 0
    fi

    return 1
}

importWithOsm2pgsql() {
    local import_style=""

    if ! import_style="$(resolveImportStyleFile)"; then
        set -
        sleep 0.1
        echo ""
        echo "ERROR: Could not find a flex osm2pgsql import script in /data/style."
        if [ -n "${NAME_STYLE:-}" ]; then
            echo "Requested NAME_STYLE=${NAME_STYLE}"
            echo "Looked for:"
            echo "  /data/style/${NAME_STYLE}"
            if [ "${NAME_STYLE#*/}" = "${NAME_STYLE}" ]; then
                echo "  /data/style/style/${NAME_STYLE}"
            fi
        else
            echo "Looked for the default files:"
            echo "  /data/style/openstreetmap-carto-flex.lua"
            echo "  /data/style/style/openstreetmap-carto-flex.lua"
        fi
        echo ""
        echo "Top-level files in /data/style:"
        ls -1 /data/style || true
        echo ""
        exit 1
    fi

    echo "INFO: Using flex style import script: /data/style/$import_style"

    sudo -E -u $USER osm2pgsql -d gis --create --slim -O flex  \
    --number-processes ${THREADS:-4}  \
    --cache ${CACHE:-2500} \
    -S /data/style/$import_style  \
    ${OSM2PGSQL_EXTRA_ARGS:-}  \
    /data/region.osm.pbf  \
    ;
}


if [ "$#" -ne 1 ]; then
    echo "usage: <import|run|debug>"
    echo "commands:"
    echo "    import: Set up the database and import /data/region.osm.pbf"
    echo "    run: Runs Apache and tirex to serve tiles at /{z}/{x}/{y}.png"
    echo "    debug: Start an infinite commande to allow shell access to container"
    echo "environment variables:"
    echo "    THREADS: defines number of threads used for importing / tile rendering"
    echo "    UPDATES: consecutive updates (enabled/disabled)"
    echo "    DROP: if enabled, osm2pgsql drops slim-mode middle tables after import"
    echo "    OSM2PGSQL_EXTRA_ARGS: extra command-line options passed to osm2pgsql during import"
    echo "    NAME_STYLE: name of the flex .lua import script to use"
    echo "    NAME_MML: name of the .mml file to render to mapnik.xml"
    echo "    NAME_SQL: name of the .sql file to use"
    exit 1
fi

set -x

ensureConfigDefaults


if [ "$1" == "import" ]; then
    # Give an error if the import is already done and exit to avoid overwriting the database.
    if [ -f /data/database/planet-import-complete ]; then
        set -
        sleep 0.1
        echo ""
        echo "ERROR: /data/database/planet-import-complete already exists."
        echo "Delete this file if you want to redo the import."
        echo "Location with the default Docker configuration : /var/lib/docker/volumes/osm-tirex_data/_data/"
        echo ""
        exit 1
    fi

    # Setup carto
    cartoBuild
    
    # Initialize PostgreSQL
    addDBConfig
    service postgresql start
    setupGisDB

    #Import external data
    chown -R $USER: /home/$USER/src/ /data/style/
    if [ -f /data/style/scripts/get-external-data.py ] && [ -f /data/style/external-data.yml ]; then
        cd /data/style
        sudo -E -u $USER python3 /data/style/scripts/get-external-data.py -C -c /data/style/external-data.yml -D /data/style/data
    fi

    #Import missing fonts
    if [ -f /data/style/scripts/get-fonts.sh ] && [ $(ls /data/style/fonts | wc -l) -lt 104 ]; then
        cd /data/style
        sudo -E -u $USER /data/style/scripts/get-fonts.sh
        cd fonts
        for i in *; do [[ ! -n `find /usr/share/fonts -name $i` ]] && cp $i /usr/share/fonts; done
    fi

    # Fail fast if the import file path exists but is not a regular file. This
    # usually means the bind mount source path on the host was wrong and Docker
    # created a directory there instead.
    if [ -e /data/region.osm.pbf ] && [ ! -f /data/region.osm.pbf ]; then
        set -
        sleep 0.1
        echo ""
        echo "ERROR: /data/region.osm.pbf exists but is not a regular file."
        echo "This usually means the host bind-mount source path is wrong or missing."
        echo "Verify the source file exists on the Docker host and recreate the container."
        echo ""
        ls -ld /data/region.osm.pbf || true
        echo ""
        exit 1
    fi

    # Download Luxembourg as sample if no data is provided
    if [ ! -f /data/region.osm.pbf ] && [ -z "${DOWNLOAD_PBF:-}" ]; then
        echo "WARNING: No import file at /data/region.osm.pbf, so importing Luxembourg as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/luxembourg.poly"
    fi

    if [ -n "${DOWNLOAD_PBF:-}" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget ${WGET_ARGS:-} "$DOWNLOAD_PBF" -O /data/region.osm.pbf
        if [ -n "${DOWNLOAD_POLY:-}" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget ${WGET_ARGS:-} "$DOWNLOAD_POLY" -O /data/region.poly
        fi
    fi

    # copy polygon file if available
    if [ -f /data/region.poly ]; then
        cp /data/region.poly /data/database/region.poly
        chown $USER: /data/database/region.poly
    fi

    # flat-nodes
    if [ "${FLAT_NODES:-}" == "enabled" ] || [ "${FLAT_NODES:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --flat-nodes /data/database/flat_nodes.bin"
    fi

    # drop slim-mode middle tables after import when updates are not needed
    if [ "${DROP:-}" == "enabled" ] || [ "${DROP:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --drop"
    fi

    # Load custom PostgreSQL functions required by the style (carto_path_type, etc.).
    # Must be applied before the import so that any flex triggers can use them,
    # and is idempotent (CREATE OR REPLACE) so safe to re-run.
    if [ -f /data/style/common-values.sql ]; then
        sudo -E -u postgres psql -d gis -f /data/style/common-values.sql
        sudo -E -u postgres psql -d gis -c "GRANT SELECT ON carto_pois TO $USER;"
    fi
    if [ -f /data/style/functions.sql ]; then
        sudo -E -u postgres psql -d gis -f /data/style/functions.sql
    fi

    # Import data
    importWithOsm2pgsql

    # Create indexes
    if [ -f /data/style/${NAME_SQL:-indexes.sql} ]; then
        sudo -E -u postgres psql -d gis -f /data/style/${NAME_SQL:-indexes.sql}
    fi

    # Register that data has changed for mod_tile caching purposes and indicate that the import is completed
    sudo -u $USER touch /data/database/planet-import-complete

    service postgresql stop

    exit 0
fi

if [ "$1" == "run" ]; then
    # Warn about missing planet-import-complete file and exit.
    if [ ! -f /data/database/planet-import-complete ]; then
        set -
        sleep 0.1
        echo ""
        echo "WARNING: /data/database/planet-import-complete is missing."
        echo "This usually means that the import process did non complete successfully."
        echo "Use the 'command import' statement in the docker-compose.yml file."
        echo ""
        exit 1
    fi

    # sync planet-import-complete files
    if [ -f /data/tiles/planet-import-complete ] && [ ! -f /data/database/planet-import-complete ]; then
        cp /data/tiles/planet-import-complete /data/database/planet-import-complete
    fi
    if [ -f /data/database/planet-import-complete ] && [ ! -f /data/tiles/planet-import-complete ]; then
        cp /data/database/planet-import-complete /data/tiles/planet-import-complete
    fi

    # Setup carto
    cartoBuild
    # Keep startup logs readable: the SVG diagnostic may inspect many referenced
    # assets, and global xtrace would otherwise print every per-file grep.
    set +x
    diagnoseUnsupportedSvgAssets /data/style
    set -x
    
    # Clean /tmp
    rm -rf /tmp/*

    # # Configure Apache CORS
    # if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
    #     echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
    # fi

    # Initialize PostgreSQL
    addDBConfig
    service postgresql start

    # Load common-values.sql (defines carto_pois lookup table and similar static
    # data). This was not applied during the original import and is required for
    # Mapnik to validate the layer SQL queries at style-load time.
    if [ -f /data/style/common-values.sql ]; then
        sudo -E -u postgres psql -d gis -f /data/style/common-values.sql
        # carto_pois is created by postgres; grant read access to the render user.
        sudo -E -u postgres psql -d gis -c "GRANT SELECT ON carto_pois TO $USER;"
    fi

    # Load custom PostgreSQL functions required by the style (carto_path_type etc.).
    # Mapnik validates every layer's SQL at style-load time; if these functions are
    # missing, every datasource fails and tirex-backend-manager loops with
    # "Cannot load any Mapnik styles". CREATE OR REPLACE makes this idempotent.
    if [ -f /data/style/functions.sql ]; then
        sudo -E -u postgres psql -d gis -f /data/style/functions.sql
    fi
    # openstreetmap-carto's indexes.sql is a plain list of CREATE INDEX statements
    # without IF NOT EXISTS, so replaying it verbatim on every container start
    # produces noisy "already exists" errors. In run mode we rewrite those CREATE
    # INDEX lines on the fly instead of patching the SQL file itself.
    sql_file="/data/style/${NAME_SQL:-indexes.sql}"
    if [ -f "$sql_file" ]; then
        if [ "$(basename "$sql_file")" = "indexes.sql" ]; then
            sed -E 's/^CREATE INDEX /CREATE INDEX IF NOT EXISTS /I' "$sql_file" \
                | sudo -E -u postgres psql -X -v ON_ERROR_STOP=1 -d gis
        else
            sudo -E -u postgres psql -d gis -f "$sql_file"
        fi
    fi

    # Configure tirex
    setupTirex
    service apache2 restart

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sleep infinity &
    sudo -u $USER /usr/bin/tirex-master -f &
    sudo -u $USER /usr/bin/tirex-backend-manager -f &
    child=$!
    wait "$child"

    service postgresql stop

    exit 0
fi

if [ "$1" == "debug" ]; then
    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sleep infinity &
    child=$!
    wait "$child"

    exit 0
fi


echo "invalid command"
exit 1
