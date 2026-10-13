# Copied from stockholm krebs/5pkgs/simple/realwallpaper (cc283503).
# nomads-cloud and grib2json are its stockholm dependencies, used only here.
{ pkgs, callPackage }:
let
  nomads-cloud = callPackage ./nomads-cloud.nix { };
in
(pkgs.writers.writeDashBin "generate-wallpaper" ''
  set -euf

  export PATH=${
    pkgs.lib.makeBinPath (
      [
        nomads-cloud
      ]
      ++ (with pkgs; [
        coreutils
        curl
        gnugrep
        gnused
        file
        findutils
        imagemagick
        inkscape
        jq
        xplanet
      ])
    )
  }

  # usage: getimg FILENAME URL
  fetch() {
    echo "fetch $1"
    curl -LsS -z "$1" -o "$1" "$2"
  }

  # usage: check_type FILENAME TYPE
  check_type() {
    if ! file -ib "$1" | grep -q "^$2/"; then
      echo "$1 is not of type $2" >&2
      rm "$1"
      return 1
    fi
  }

  # check if file exists and fetch only if missing
  fetch_once() {
    name=$1
    url=$2
    test -e "$name" || fetch "$name" "$url"
  }

  fetch_older_min() {
    min=$1
    name=$2
    url=$3
    if ! test "$(find $name -mmin -$min)"; then
      fetch "$name" "$url"
    fi
  }

  fetch_older_days() {
    days=$1
    name=$2
    url=$3
    if ! test "$(find $name -mtime -$days)"; then
      fetch "$name" "$url"
    fi
  }

  # usage: needs_rebuild DST SRC...
  needs_rebuild() {
    a="$1"
    shift
    if ! test -e "$a"; then
      #echo "  $a does not exist" >&2
      result=0
    else
      result=1
      for b; do
        if check_type "$b" image; then
          if test "$b" -nt "$a"; then
            #echo "  $b is newer than $a" >&2
            result=0
          fi
        fi
      done
    fi
    #case $result in
    #  0) echo "$a needs rebuild" >&2;;
    #esac
    return $result
  }

  get_neo_url() {
    url=$1
    curl -Ss "$url" | grep '3600 x 1800' | sed 's/.*href="\([^"]*\)".*/\1/'
  }

  main() {
    cd "''${working_dir:-$PWD}"

    # fetch source images in parallel
    fetch_once nightmap-raw.jpg \
      'https://eoimages.gsfc.nasa.gov/images/imagerecords/144000/144898/BlackMarble_2016_3km.jpg' &
    fetch_once daymap-raw.tif \
      'https://eoimages.gsfc.nasa.gov/images/imagerecords/57000/57752/land_shallow_topo_8192.tif' &

    fetch_once mercury-raw.svg \
      'https://upload.wikimedia.org/wikipedia/commons/2/2e/Mercury_symbol.svg' &
    fetch_once venus-raw.svg \
      'https://upload.wikimedia.org/wikipedia/commons/6/66/Venus_symbol.svg' &
    fetch_once mars-raw.svg \
      'https://upload.wikimedia.org/wikipedia/commons/b/b7/Mars_symbol.svg' &
    fetch_once jupiter-raw.svg \
      'https://upload.wikimedia.org/wikipedia/commons/2/26/Jupiter_symbol.svg' &
    fetch_once saturn-raw.svg \
      'https://upload.wikimedia.org/wikipedia/commons/7/74/Saturn_symbol.svg' &
    fetch_once uranus-raw.svg \
      'https://upload.wikimedia.org/wikipedia/commons/f/f1/Uranus_symbol.svg' &
    fetch_once neptune-raw.svg \
      'https://upload.wikimedia.org/wikipedia/commons/4/47/Neptune_symbol.svg' &

    fetch_once krebs-raw.svg \
      'https://raw.githubusercontent.com/krebs/painload/master/cholerab/bling/krebs_aquarium.svg' &

    fetch_older_min 720 ice-raw.jpg $(get_neo_url \
      'https://neo.gsfc.nasa.gov/view.php?datasetId=NISE_D') &
    fetch_older_days 1 snow-raw.jpg $(get_neo_url \
      'https://neo.gsfc.nasa.gov/view.php?datasetId=MOD10C1_E_SNOW') &
    fetch_older_days 1 chlora-raw.jpg $(get_neo_url \
      'https://neo.gsfc.nasa.gov/view.php?datasetId=MY1DMM_CHLORA') &
    fetch_older_days 1 fire-raw.jpg $(get_neo_url \
      'https://neo.gsfc.nasa.gov/view.php?datasetId=MOD14A1_E_FIRE') &

    # regular fetches
    fetch marker.json.tmp "''${marker_url:-}" || :
    if [ -s marker.json.tmp ]; then
      mv marker.json.tmp marker.json
    fi
    fetch sun-raw.jpg 'https://sdo.gsfc.nasa.gov/assets/img/latest/latest_512_0171.jpg' &

    wait

    # fetch clouds if they are older than 3h
    if ! test "$(find clouds-raw.png -mmin -180)"; then
      nomads-cloud clouds-raw.png
    fi

    in_size=3600x1800
    xplanet_out_size=3200x2500
    out_geometry=3200x1800+0+350

    for raw in \
        nightmap-raw.jpg \
        daymap-raw.tif \
        chlora-raw.jpg \
        clouds-raw.png \
        ;
    do
      normal=''${raw%-raw.*}.png
      if needs_rebuild $normal $raw; then
        echo "make $normal; normalize $raw" >&2
        convert $raw -scale $in_size $normal
      fi
    done

    # remove snow from ice map
    if needs_rebuild ice.png ice-raw.jpg; then
      convert ice-raw.jpg -fuzz 20% -fill black -opaque white -colorspace gray -blur 0x6 -scale "$in_size" ice.png
    fi

    if needs_rebuild snow.png snow-raw.jpg; then
      convert snow-raw.jpg -fuzz 20% -fill '#DEDEDE' -opaque white -scale "$in_size" snow.png
    fi

    # make fire more red
    if needs_rebuild fire.png fire-raw.jpg; then
      convert fire-raw.jpg -fuzz 20% -fill '#ef840c' -opaque white -scale "$in_size" fire.png
    fi

    # cut out sun with alpha transparency
    if needs_rebuild sun.png sun-raw.jpg; then
      convert sun-raw.jpg \
        \( +clone -colorspace HSB -fill white -draw "circle 256,256 256,54" -separate -delete 0,1 \) \
        -compose copyopacity -composite -crop 512x472+0+20 -scale "100x100" sun.png
    fi

    if needs_rebuild krebs.png krebs-raw.svg; then
      inkscape --export-type="png" --export-width=16 --export-height=16 --export-filename=krebs.png krebs-raw.svg
    fi

    # -- Planets --
    for planet in mercury venus mars jupiter saturn uranus neptune; do
      if needs_rebuild "$planet".png "$planet"-raw.svg; then
        sed -i 's/#000/#FE8019/g' "$planet"-raw.svg
        inkscape --export-type="png" --export-width=40 --export-height=40 --export-filename="$planet.png" "$planet-raw.svg"
      fi
    done

    # -- Daymap --

    # merge with water chlora layer
    if needs_rebuild daymap-final.png daymap.png fire.png snow.png ice.png chlora.png; then
      convert daymap.png fire.png -compose lighten -composite daymap-1.png
      convert daymap-1.png ice.png -compose lighten -composite daymap-2.png
      convert daymap-2.png snow.png -compose lighten -composite daymap-3.png
      convert daymap-3.png chlora.png -compose lighten -composite daymap-final.png
    fi

    # -- Nightmap --

    if needs_rebuild nightmap-final.png nightmap.png fire.png snow.png ice.png chlora.png; then
      convert nightmap.png fire.png -compose lighten -composite nightmap-1.png
      convert nightmap-1.png \( -fill black -colorize 70% ice.png \) -compose lighten -composite nightmap-2.png
      convert nightmap-2.png \( -fill black -colorize 70% snow.png \) -compose lighten -composite nightmap-3.png
      convert nightmap-3.png \( -fill black -colorize 70% chlora.png \) -compose lighten -composite nightmap-final.png
    fi

    # create marker file from json
    echo 'position=sun image=sun.png' > marker_file
    echo 'position=moon image=moon.png' >> marker_file
    echo 'position=mercury image=mercury.png' >> marker_file
    echo 'position=venus image=venus.png' >> marker_file
    echo 'position=mars image=mars.png' >> marker_file
    echo 'position=jupiter image=jupiter.png' >> marker_file
    echo 'position=saturn image=saturn.png' >> marker_file
    echo 'position=uranus image=uranus.png' >> marker_file
    echo 'position=neptune image=neptune.png' >> marker_file

    # generate moon
    xplanet -body moon --num_times 1 -origin earth \
      --transpng moon.png --geometry 50x50 \
      -config ${pkgs.writeText "moon.config" ''
        [moon]
        shade=10
      ''}

    # rebuild every time to update shadow
    xplanet --num_times 1 --geometry $xplanet_out_size \
      --output xplanet-output.png --projection merc \
      -config ${pkgs.writeText "xplanet.config" ''
        [earth]
        "Earth"
        map=daymap-final.png
        night_map=nightmap-final.png
        cloud_map=clouds.png
        cloud_threshold=1
        cloud_gamma=10
        shade=15
      ''}

    xplanet --num_times 1 --geometry $xplanet_out_size \
      --output xplanet-marker-output.png --projection merc \
      -config ${pkgs.writeText "xplanet-marker.config" ''
        [earth]
        "Earth"
        map=daymap-final.png
        night_map=nightmap-final.png
        cloud_map=clouds.png
        cloud_threshold=1
        cloud_gamma=10
        marker_file=marker_file
        shade=15
      ''}

    if [ -s marker.json ]; then
      jq -r 'to_entries[] | select(.value.latitude != null) | @json "\(.value.latitude) \(.value.longitude) image=krebs.png"' marker.json >> marker_file
    fi

    xplanet --num_times 1 --geometry $xplanet_out_size \
      --output xplanet-krebs-output.png --projection merc \
      -config ${pkgs.writeText "xplanet-krebs.config" ''
        [earth]
        "Earth"
        map=daymap-final.png
        night_map=nightmap-final.png
        cloud_map=clouds.png
        cloud_threshold=1
        cloud_gamma=10
        marker_file=marker_file
        shade=15
      ''}

    ${
      pkgs.writers.writePython3 "get_constellations" {
        libraries = [ pkgs.python3Packages.astropy ];
      } ./get_constellations.py
    } ${
      pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/ofrohn/d3-celestial/7e720a3de062059d4c5400a379146a601d9010e0/data/constellations.lines.json";
        hash = "sha256-KU9mvvXVz1Cx4X8W0u+h2XoVExYSxo3ZNa3vbnNz4Tw=";
      }
    } > constellations.arcs || :  # seems like astropy doesn't want to convert from icrs to itrs anymore

    xplanet --num_times 1 --geometry $xplanet_out_size \
      --output xplanet-krebs-stars-output.png --projection merc \
      -config ${pkgs.writeText "xplanet-krebs-stars.config" ''
        [default]

        arc_thickness=1
        arc_file=constellations.arcs

        [earth]
        "Earth"
        map=daymap-final.png
        night_map=nightmap-final.png
        cloud_map=clouds.png
        cloud_threshold=1
        cloud_gamma=10
        marker_file=marker_file
        shade=15
      ''}

    xplanet --num_times 1 --geometry $xplanet_out_size \
      --latitude 52.520008 --longitude 13.404954 \
      --output xplanet-krebs-stars-berlin-output.png --projection merc \
      -config ${pkgs.writeText "xplanet-krebs-stars.config" ''
        [default]

        arc_thickness=1
        arc_file=constellations.arcs

        [earth]
        "Earth"
        map=daymap-final.png
        night_map=nightmap-final.png
        cloud_map=clouds.png
        cloud_threshold=1
        cloud_gamma=10
        marker_file=marker_file
        shade=15
      ''}

    # trim xplanet output
    if needs_rebuild realwallpaper.png xplanet-output.png; then
      convert xplanet-output.png -crop $out_geometry \
        realwallpaper-tmp.png
        mv realwallpaper-tmp.png realwallpaper.png
    fi

    if needs_rebuild realwallpaper-marker.png xplanet-marker-output.png; then
      convert xplanet-marker-output.png -crop $out_geometry \
        realwallpaper-marker-tmp.png
        mv realwallpaper-marker-tmp.png realwallpaper-marker.png
    fi

    if needs_rebuild realwallpaper-krebs.png xplanet-krebs-output.png; then
      convert xplanet-krebs-output.png -crop $out_geometry \
        realwallpaper-krebs-tmp.png
        mv realwallpaper-krebs-tmp.png realwallpaper-krebs.png
        mkdir -p archive
        convert realwallpaper-krebs.png archive/"$(date -Is)".jpg
    fi

    if needs_rebuild realwallpaper-krebs-stars.png xplanet-krebs-stars-output.png; then
      convert xplanet-krebs-stars-output.png -crop $out_geometry \
        realwallpaper-krebs-stars-tmp.png
        mv realwallpaper-krebs-stars-tmp.png realwallpaper-krebs-stars.png
    fi

    if needs_rebuild realwallpaper-krebs-stars-berlin.png xplanet-krebs-stars-berlin-output.png; then
      convert xplanet-krebs-stars-berlin-output.png -crop $out_geometry \
        realwallpaper-krebs-stars-berlin-tmp.png
        mv realwallpaper-krebs-stars-berlin-tmp.png realwallpaper-krebs-stars-berlin.png
    fi
  }

  main "$@"
'').overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      updateScript = ./update.sh;
    };
  })
