# osm-tirex by dfjs1m

This is based on openstreetmap-tile-server, available on GitHub, by Alexander Overvoorde.

I have modified it to run with tirex instead of renderd. It also compiles the latest version of osm2pgsql during the creation of the Docker image and uses PostgreSQL 18.

There are 6 main components being installed in the Docker image to get this to work :
  - PostgreSQL
  - osm2pgsql
  - openstreetmap-carto
  - Apache2
  - mod_tile
  - tirex

The configuration files are in the "config" sub-directory and are being copied inside the docker image during the Docker building process.

The bundled demo page in `config/index.html` now uses the same host and port that served the page, so it should work out of the box at `http://HOST:8080/tirex-region/`. You should only need to edit it if you are putting the service behind a reverse proxy with a different public path.

A lot of performance and RAM tweaking can be done in the following configuration files :
  - config/mapnik.conf
  - config/postgresql.custom.conf
  - config/tirex.conf

## Documentation in this repository

  - `docs/tile-server-notes.md` — PostgreSQL/PostGIS setup, the osm2pgsql import
    invocation, kernel and huge-page tuning for a large import, and index checks.
  - `docs/Cellebrite setup/` — pointing Cellebrite Physical Analyzer / Reader at
    this tile server for offline maps. Set `TILE_SERVER_HOST` at the top of the
    `.cmd` to your own tile server before running it.


# Setup
Download the region file in "osm.pbf" format that you want from Geofabrik's free download server :
  https://download.geofabrik.de/

* Since the import process can take a very long time (even days for the whole planet on a decently fast computer), it is recommanded to start
  by testing with a small region.

Edit the docker-compose.yml file to map "/data/region.osm.pbf" to the file you downloaded in the volumes section. For example :
      - /path/to/downloaded/region-latest.osm.pbf:/data/region.osm.pbf

Also make sure only the "import" command is commented out.

Run the following command from the directory where you cloned the osm-tirex GitHub repository :
  docker compose up --build osm-tirex

If you are upgrading from an older image that used a previous PostgreSQL major version, do not reuse the old `/data/database` contents for a fresh import. PostgreSQL data files are not portable across major versions without a dedicated upgrade procedure, so the safest path for this project is to remove the existing database volume and re-import the `.osm.pbf` extract.

Once the import process is completed, uncomment only the "run" command from the docker-compose.yml file and run the previous command again.

If you want to start the Docker container in the background, start it with the following command :
  docker compose up --build -d osm-tirex
 
To start a shell in the Docker container, run the following command :
  docker compose exec osm-tirex bash


# Possible errors

When trying to run the Docker, if it fails with this error :
+ sudo -u postgres psql -c 'ALTER USER _tirex PASSWORD '\''_tirex'\'''

It usually means that there was a problem with the "import" part and the database has not been created properly.


# openstreetmap-tile-server

[![Build Status](https://travis-ci.org/Overv/openstreetmap-tile-server.svg?branch=master)](https://travis-ci.org/Overv/openstreetmap-tile-server) [![](https://images.microbadger.com/badges/image/overv/openstreetmap-tile-server.svg)](https://microbadger.com/images/overv/openstreetmap-tile-server "openstreetmap-tile-server")
[![Docker Image Version (latest semver)](https://img.shields.io/docker/v/overv/openstreetmap-tile-server?label=docker%20image)](https://hub.docker.com/r/overv/openstreetmap-tile-server/tags)

This container allows you to easily set up an OpenStreetMap PNG tile server given a `.osm.pbf` file. It follows the switch2osm tile-server workflow, updated here for a modern Ubuntu base image and current PostgreSQL releases, and therefore uses the default OpenStreetMap style.


## Setting up the server

First create a Docker volume to hold the PostgreSQL database that will contain the OpenStreetMap data:

    docker volume create osm-data

Next, download an `.osm.pbf` extract from geofabrik.de for the region that you're interested in. You can then start importing it into PostgreSQL by running a container and mounting the file as `/data/region.osm.pbf`. For example:

```
docker run \
    -v /absolute/path/to/luxembourg.osm.pbf:/data/region.osm.pbf \
    -v osm-data:/data/database/ \
    overv/openstreetmap-tile-server \
    import
```

If the container exits without errors, then your data has been successfully imported and you are now ready to run the tile server.

Note that the import process requires an internet connection. The run process does not require an internet connection. If you want to run the openstreetmap-tile server on a computer that is isolated, you must first import on an internet connected computer, export the `osm-data` volume as a tarfile, and then restore the data volume on the target computer system.

The default `index.html` now uses bundled Leaflet assets from this repository, so it will also work on isolated systems.


### Automatic updates (optional)

If your import is an extract of the planet and has polygonal bounds associated with it, like those from [geofabrik.de](https://download.geofabrik.de/), then it is possible to set your server up for automatic updates. Make sure to reference both the OSM file and the polygon file during the `import` process to facilitate this, and also include the `UPDATES=enabled` variable:

```
docker run \
    -e UPDATES=enabled \
    -v /absolute/path/to/luxembourg.osm.pbf:/data/region.osm.pbf \
    -v /absolute/path/to/luxembourg.poly:/data/region.poly \
    -v osm-data:/data/database/ \
    overv/openstreetmap-tile-server \
    import
```

Refer to the section *Automatic updating and tile expiry* to actually enable the updates while running the tile server.

Please note: If you're not importing the whole planet, then the `.poly` file is necessary to limit automatic updates to the relevant region.
Therefore, when you only have a `.osm.pbf` file but not a `.poly` file, you should not enable automatic updates.


### Letting the container download the file

It is also possible to let the container download files for you rather than mounting them in advance by using the `DOWNLOAD_PBF` and `DOWNLOAD_POLY` parameters:

```
docker run \
    -e DOWNLOAD_PBF=https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf \
    -e DOWNLOAD_POLY=https://download.geofabrik.de/europe/luxembourg.poly \
    -v osm-data:/data/database/ \
    overv/openstreetmap-tile-server \
    import
```


### Using an alternate style

By default the container will use openstreetmap-carto if it is not specified. However, you can modify the style at run-time. Be aware you need the style mounted at `run` AND `import` because the same directory provides both the flex import script and the rendered map style:

```
docker run \
    -e DOWNLOAD_PBF=https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf \
    -e DOWNLOAD_POLY=https://download.geofabrik.de/europe/luxembourg.poly \
    -e NAME_STYLE=sample-flex.lua \
    -e NAME_MML=project.mml \
    -e NAME_SQL=test.sql \
    -v /home/user/openstreetmap-carto-modified:/data/style/ \
    -v osm-data:/data/database/ \
    overv/openstreetmap-tile-server \
    import
```

If you do not define `NAME_STYLE`, the script defaults to `openstreetmap-carto-flex.lua` from the mounted style directory.

Be sure to mount the volume during `run` with the same `-v /home/user/openstreetmap-carto-modified:/data/style/`

If you do not see the expected style upon `run`, double check your paths and rebuild the image if needed. During `import`, the container now fails fast when the flex import script cannot be found in the mounted style directory.

**Only flex-based styles are supported for import.** In practice that means a style directory needs a flex Lua import script, an MML/project file for `carto`, and any optional SQL post-processing files it expects.


## Running the server

Run the server like this:

```
docker run \
    -p 8080:80 \
    -v osm-data:/data/database/ \
    -d overv/openstreetmap-tile-server \
    run
```

Your tiles will now be available at `http://localhost:8080/tile/{z}/{x}/{y}.png`. The demo map in `leaflet-demo.html` will then be available on `http://localhost:8080`. Note that it will initially take quite a bit of time to render the larger tiles for the first time.


### Using Docker Compose

The `docker-compose.yml` file included with this repository shows how the aforementioned command can be used with Docker Compose to run your server.


### Preserving rendered tiles

Tiles that have already been rendered will be stored in `/data/tiles/`. To make sure that this data survives container restarts, you should create another volume for it:

```
docker volume create osm-tiles
docker run \
    -p 8080:80 \
    -v osm-data:/data/database/ \
    -v osm-tiles:/data/tiles/ \
    -d overv/openstreetmap-tile-server \
    run
```

**If you do this, then make sure to also run the import with the `osm-tiles` volume to make sure that caching works properly across updates!**


### Enabling automatic updating (optional)

Given that you've set up your import as described in the *Automatic updates* section during server setup, you can enable the updating process by setting the `UPDATES` variable while running your server as well:

```
docker run \
    -p 8080:80 \
    -e REPLICATION_URL=https://planet.openstreetmap.org/replication/minute/ \
    -e MAX_INTERVAL_SECONDS=60 \
    -e UPDATES=enabled \
    -v osm-data:/data/database/ \
    -v osm-tiles:/data/tiles/ \
    -d overv/openstreetmap-tile-server \
    run
```

This will enable a background process that automatically downloads changes from the OpenStreetMap server, filters them for the relevant region polygon you specified, updates the database and finally marks the affected tiles for rerendering.


### Tile expiration (optional)

Specify custom tile expiration settings to control which zoom level tiles are marked as expired when an update is performed. Tiles can be marked as expired in the cache (TOUCHFROM), but will still be served
until a new tile has been rendered, or deleted from the cache (DELETEFROM), so nothing will be served until a new tile has been rendered.

The example tile expiration values below are the default values.

```
docker run \
    -p 8080:80 \
    -e REPLICATION_URL=https://planet.openstreetmap.org/replication/minute/ \
    -e MAX_INTERVAL_SECONDS=60 \
    -e UPDATES=enabled \
    -e EXPIRY_MINZOOM=13 \
    -e EXPIRY_TOUCHFROM=13 \
    -e EXPIRY_DELETEFROM=19 \
    -e EXPIRY_MAXZOOM=20 \
    -v osm-data:/data/database/ \
    -v osm-tiles:/data/tiles/ \
    -d overv/openstreetmap-tile-server \
    run
```


### Cross-origin resource sharing

To enable the `Access-Control-Allow-Origin` header to be able to retrieve tiles from other domains, simply set the `ALLOW_CORS` variable to `enabled`:

```
docker run \
    -p 8080:80 \
    -v osm-data:/data/database/ \
    -e ALLOW_CORS=enabled \
    -d overv/openstreetmap-tile-server \
    run
```


### Connecting to Postgres

To connect to the PostgreSQL database inside the container, make sure to expose port 5432:

```
docker run \
    -p 8080:80 \
    -p 5432:5432 \
    -v osm-data:/data/database/ \
    -d overv/openstreetmap-tile-server \
    run
```

Use the user `renderer` and the database `gis` to connect.

```
psql -h localhost -U renderer gis
```

The default password is `renderer`, but it can be changed using the `PGPASSWORD` environment variable:

```
docker run \
    -p 8080:80 \
    -p 5432:5432 \
    -e PGPASSWORD=secret \
    -v osm-data:/data/database/ \
    -d overv/openstreetmap-tile-server \
    run
```


## Performance tuning and tweaking

Details for update procedure and invoked scripts can be found here [link](https://ircama.github.io/osm-carto-tutorials/updating-data/).


### THREADS

The import and tile serving processes use 4 threads by default, but this number can be changed by setting the `THREADS` environment variable. For example:
```
docker run \
    -p 8080:80 \
    -e THREADS=24 \
    -v osm-data:/data/database/ \
    -d overv/openstreetmap-tile-server \
    run
```

### CACHE

The import and tile serving processes use 800 MB RAM cache by default, but this number can be changed by option -C. For example:
```
docker run \
    -p 8080:80 \
    -e "OSM2PGSQL_EXTRA_ARGS=-C 4096" \
    -v osm-data:/data/database/ \
    -d overv/openstreetmap-tile-server \
    run
```

### AUTOVACUUM

The database use the autovacuum feature by default. This behavior can be changed with `AUTOVACUUM` environment variable. For example:
```
docker run \
    -p 8080:80 \
    -e AUTOVACUUM=off \
    -v osm-data:/data/database/ \
    -d overv/openstreetmap-tile-server \
    run
```

### FLAT_NODES

If you are planning to import the entire planet or you are running into memory errors then you may want to enable the `--flat-nodes` option for osm2pgsql. You can then use it during the import process as follows:

```
docker run \
    -v /absolute/path/to/luxembourg.osm.pbf:/data/region.osm.pbf \
    -v osm-data:/data/database/ \
    -e "FLAT_NODES=enabled" \
    overv/openstreetmap-tile-server \
    import
```

Warning: enabling `FLAT_NOTES` together with `UPDATES` only works for entire planet imports (without a `.poly` file).  Otherwise this will break the automatic update script. This is because trimming the differential updates to the specific regions currently isn't supported when using flat nodes.


### DROP

If you do not need live updates, you can ask `osm2pgsql` to drop the slim-mode middle tables automatically once the import has completed successfully. This reduces disk usage after the import, avoids building persistent middle-table indexes that are only needed for updates, but it must be decided at import time and it makes later updates impossible without a full re-import.

```
docker run \
    -v /absolute/path/to/luxembourg.osm.pbf:/data/region.osm.pbf \
    -v osm-data:/data/database/ \
    -e DROP=enabled \
    overv/openstreetmap-tile-server \
    import
```

If you prefer full control, you can still pass raw flags through `OSM2PGSQL_EXTRA_ARGS`.


### Large extract retry profile

If an import reaches the end and then crashes during clustering or index creation, the failure is usually in the high-memory postprocessing phase rather than in the style file or input data.

For large extracts on a VM where you can temporarily increase RAM for the import phase, the most reliable retry profile is:

- temporarily raise the VM to at least 32 GB RAM; 64 GB is even better
- set `DROP=enabled` so `osm2pgsql` skips the persistent slim-table indexes used only for updates
- set `OSM2PGSQL_EXTRA_ARGS=--disable-parallel-indexing` so clustering and index builds run one at a time instead of all at once
- start with `THREADS=4`
- use a moderate `CACHE` value such as `4000` to `8000`

If an import fails, the safest recovery is a fresh re-import into a clean database volume.


### Benchmarks

You can find an example of the import performance to expect with this image on the [OpenStreetMap wiki](https://wiki.openstreetmap.org/wiki/Osm2pgsql/benchmarks#debian_9_.2F_openstreetmap-tile-server).


## Pre-rendering
# Whole world, zoom 1-8 (fast, ~hundreds of metatiles)
sudo docker compose exec osm-tirex \
  sudo -u _tirex tirex-batch --prio=20 --num=100 \
  map=region z=1-8 bbox=-180,-85,180,85

# Eastern Canada, zoom 9-12
sudo docker compose exec osm-tirex \
  sudo -u _tirex tirex-batch --prio=20 --num=100 \
  map=region z=9-12 bbox=-80,44,-60,52

# Use --count-only first to see how many tiles would be queued before committing:
sudo docker compose exec osm-tirex \
  sudo -u _tirex tirex-batch --prio=20 --count-only \
  map=region z=9-12 bbox=-80,44,-60,52


## Troubleshooting

### ERROR: could not resize shared memory segment / No space left on device

If you encounter such entries in the log, it will mean that the default shared memory limit (64 MB) is too low for the container and it should be raised:
```
renderd[121]: ERROR: failed to render TILE default 2 0-3 0-3
renderd[121]: reason: Postgis Plugin: ERROR: could not resize shared memory segment "/PostgreSQL.790133961" to 12615680 bytes: ### No space left on device
```
To raise it use `--shm-size` parameter. For example:
```
docker run \
    -p 8080:80 \
    -v osm-data:/data/database/ \
    --shm-size="192m" \
    -d overv/openstreetmap-tile-server \
    run
```
For too high values you may notice excessive CPU load and memory usage. It might be that you will have to experimentally find the best values for yourself.

### The import process unexpectedly exits

You may be running into problems with memory usage during the import. Have a look at the "Flat nodes" section in this README.

### The image build fails with `NLOHMANN_INCLUDE_DIR-NOTFOUND`

Recent versions of `osm2pgsql` require the `nlohmann-json` headers during the build. If the Docker build stops during the `compiler-osm2pgsql` stage with `NLOHMANN_INCLUDE_DIR-NOTFOUND`, update to a version of this repository that installs `nlohmann-json3-dev` in the build stage and rebuild the image.

### The container starts once but fails after a restart with `mv: cannot stat '/usr/share/tirex/example-map'`

Some Ubuntu package combinations ship the Apache example-map configuration without also shipping the `/usr/share/tirex/example-map` directory. Recent versions of this repository no longer assume that directory exists and instead bundle the Leaflet assets needed by the demo page directly in the image.

If you hit this error on an older image, rebuild the image from the updated sources before starting the service again.

### The container exits with `cp: cannot overwrite directory '/usr/share/tirex/region/./leaflet' with non-directory`

Some Ubuntu `tirex-example-map` packages install `leaflet` as a file or symlink inside `/usr/share/tirex/example-map`. Recent versions of this repository copy the example-map contents first and then replace that path with a real directory containing bundled Leaflet assets.

If you hit this error on an older image, rebuild from the updated sources and start the container again.

### The demo page loads but stays gray

If `http://HOST:8080/tirex-region/` opens but shows only a gray page, check the page source or browser dev tools for a tile URL like `http://{IP or HOSTNAME}:8080/{z}/{x}/{y}.png`. That means your persistent Docker `config` volume still contains an older `index.html` from before the demo page used a relative tile path.

Current images automatically repair that exact legacy placeholder during startup. If you are still on an older image, rebuild from the updated sources or remove the `config` volume once so Docker can repopulate it from the image defaults.

### Mapnik logs `SVG PARSING ERROR: "SVG support error: <clip-path> attribute is not supported"`

That warning usually comes from one of the SVG icons or pattern files in the runtime style directory under `/data/style`. During `run` mode, the container now scans the generated `mapnik.xml` (the compiled result of the CartoCSS/MML style) for referenced `.svg` assets and then checks only those files for `clip-path` or `clipPath`, so the log focuses on likely runtime offenders instead of unrelated source SVGs.

The warning is usually non-fatal: tiles still render, but the affected symbol may be missing or simplified. If you want to eliminate it, replace the reported SVG with a simpler "plain SVG" export or remove the clipping construct from that asset.

## License

```
Copyright 2019 Alexander Overvoorde

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
