#!/bin/bash

CHAOSP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ADD_MAGISK=false
ADD_OPENGAPPS=false

mkdir -p $CHAOSP_DIR/revisions
mkdir -p $CHAOSP_DIR/revisions/fdroid
mkdir -p $CHAOSP_DIR/revisions/fdroid-priv


usage(){
  echo "./build.sh [-m (add Magisk)] [-g (add OpenGapps)] device_name"
  exit 1
}


while getopts ":mgh" opt; do
  case $opt in
    m) ADD_MAGISK=true
    ;;
    g) ADD_OPENGAPPS=true
    ;;
    *) usage;;
  esac
done

if [ $# -lt 1 ]; then
  echo "Need to specify device name as argument"
  exit 1
fi

if [ $# -eq 2 ]; then
  DEVICE=$2
else
  # check if supported device
  DEVICE=$1
fi

case "$DEVICE" in
  marlin|sailfish)
    DEVICE_FAMILY=marlin
    KERNEL_FAMILY=marlin
    KERNEL_DEFCONFIG=marlin
    AVB_MODE=verity_only
    ;;
  taimen)
    DEVICE_FAMILY=taimen
    KERNEL_FAMILY=wahoo
    KERNEL_DEFCONFIG=wahoo
    AVB_MODE=vbmeta_simple
    ;;
  walleye)
    DEVICE_FAMILY=muskie
    KERNEL_FAMILY=wahoo
    KERNEL_DEFCONFIG=wahoo
    AVB_MODE=vbmeta_simple
    ;;
  crosshatch|blueline)
    DEVICE_FAMILY=crosshatch
    KERNEL_FAMILY=crosshatch
    KERNEL_DEFCONFIG=b1c1
    AVB_MODE=vbmeta_chained
    EXTRA_OTA=(--retrofit_dynamic_partitions)
    ;;
  sargo|bonito)
    DEVICE_FAMILY=bonito
    KERNEL_FAMILY=bonito
    KERNEL_DEFCONFIG=bonito
    AVB_MODE=vbmeta_chained
    EXTRA_OTA=(--retrofit_dynamic_partitions)
    ;;
  flame|coral)
    DEVICE_FAMILY=coral
    KERNEL_FAMILY=coral
    KERNEL_DEFCONFIG=coral
    AVB_MODE=vbmeta_chained_v2
    ;;
  sunfish)
    DEVICE_FAMILY=sunfish
    KERNEL_FAMILY=sunfish
    KERNEL_DEFCONFIG=sunfish
    AVB_MODE=vbmeta_chained_v2
    ;;
  *)
    echo "warning: unknown device $DEVICE, using Pixel 3 defaults"
    DEVICE_FAMILY=$1
    KERNEL_FAMILY=crosshatch
    KERNEL_DEFCONFIG=b1c1
    AVB_MODE=vbmeta_chained
    ;;
esac

# this is a build time option to override stack setting IGNORE_VERSION_CHECKS
FORCE_BUILD=false
if [ "$2" = true ]; then
  echo "Setting FORCE_BUILD=true"
  FORCE_BUILD=true
fi

# allow build and branch to be specified
AOSP_BUILD=$3
AOSP_BRANCH=$4
AOSP_VENDOR_BUILD=

# version of chromium to pin to if requested
#CHROMIUM_PINNED_VERSION=<% .ChromiumVersion %>

# Whether the kernel needs to be rebuilt
# It is always rebuilt for marlin/sailfish
ENABLE_KERNEL_BUILD=false

# whether keys are client side encrypted or not
ENCRYPTED_KEYS=false
ENCRYPTION_KEY=
ENCRYPTION_PIPE="/tmp/key"

# pin to specific version of android
ANDROID_VERSION="10.0"

# build type (user or userdebug)
BUILD_TYPE="user"

# build channel (stable or beta)
BUILD_CHANNEL="stable"

# user customizable things
#HOSTS_FILE="https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-social/hosts"
HOSTS_FILE=

# build settings
SECONDS=0
BUILD_TARGET="release aosp_${DEVICE} ${BUILD_TYPE}"
RELEASE_URL="https://${AWS_RELEASE_BUCKET}.s3.amazonaws.com"
RELEASE_CHANNEL="${DEVICE}-${BUILD_CHANNEL}"
CHROME_CHANNEL="stable"
BUILD_DATE=$(date +%Y.%m.%d.%H)
BUILD_TIMESTAMP=$(date +%s)
BUILD_DIR="$CHAOSP_DIR/rattlesnake-os"
KEYS_DIR="${BUILD_DIR}/keys"
CERTIFICATE_SUBJECT='/CN=RattlesnakeOS'
OFFICIAL_FDROID_KEY="43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab"
KERNEL_SOURCE_DIR="${CHAOSP_DIR}/kernel/google/${KERNEL_FAMILY}"
BUILD_REASON=""

# urls
ANDROID_SDK_URL="https://dl.google.com/android/repository/sdk-tools-linux-4333796.zip"
MANIFEST_URL="https://android.googlesource.com/platform/manifest"
KERNEL_SOURCE_URL="https://android.googlesource.com/kernel/msm"
AOSP_URL_BUILD="https://developers.google.com/android/images"
AOSP_URL_PLATFORM_BUILD="https://android.googlesource.com/platform/build"
RATTLESNAKEOS_LATEST_JSON="https://raw.githubusercontent.com/hackt3am/latest/${ANDROID_VERSION}"
RATTLESNAKEOS_LATEST_JSON_AOSP="${RATTLESNAKEOS_LATEST_JSON}/aosp.json"
RATTLESNAKEOS_LATEST_JSON_CHROMIUM="${RATTLESNAKEOS_LATEST_JSON}/chromium.json"
RATTLESNAKEOS_LATEST_JSON_FDROID="${RATTLESNAKEOS_LATEST_JSON}/fdroid.json"

LATEST_CHROMIUM=
FDROID_CLIENT_VERSION=
FDROID_PRIV_EXT_VERSION=

get_latest_versions() {
  log_header ${FUNCNAME}

  # check for latest chromium version
  LATEST_CHROMIUM=$(curl --fail -s "${RATTLESNAKEOS_LATEST_JSON_CHROMIUM}" | jq -r ".$CHROME_CHANNEL")
  if [ -z "$LATEST_CHROMIUM" ]; then
    echo "ERROR: Unable to get latest Chromium version details. Stopping build."
    exit 1
  fi
  echo "LATEST_CHROMIUM=${LATEST_CHROMIUM}"

  FDROID_CLIENT_VERSION=$(curl --fail -s "${RATTLESNAKEOS_LATEST_JSON_FDROID}" | jq -r ".client")
  if [ -z "$FDROID_CLIENT_VERSION" ]; then
    echo "ERROR: Unable to get latest F-Droid version details. Stopping build."
    exit 1
  fi
  echo "FDROID_CLIENT_VERSION=${FDROID_CLIENT_VERSION}"

  FDROID_PRIV_EXT_VERSION=$(curl --fail -s "${RATTLESNAKEOS_LATEST_JSON_FDROID}" | jq -r ".privilegedextention")
  if [ -z "$FDROID_PRIV_EXT_VERSION" ]; then
    echo "ERROR: Unable to get latest F-Droid privilege extension version details. Stopping build."
    exit 1
  fi
  echo "FDROID_PRIV_EXT_VERSION=${FDROID_PRIV_EXT_VERSION}"

  AOSP_VENDOR_BUILD=$(curl --fail -s "${RATTLESNAKEOS_LATEST_JSON_AOSP}" | jq -r ".${DEVICE}.build")
  if [ -z "AOSP_VENDOR_BUILD" ]; then
    echo "ERROR: Unable to get latest AOSP build version details. Stopping build."
    exit 1
  fi
  if [ -z "$AOSP_BUILD" ]; then
    AOSP_BUILD=${AOSP_VENDOR_BUILD}
  fi
  echo "AOSP_VENDOR_BUILD=${AOSP_VENDOR_BUILD}"
  echo "AOSP_BUILD=${AOSP_BUILD}"

  if [ -z "$AOSP_BRANCH" ]; then
    AOSP_BRANCH=$(curl --fail -s "${RATTLESNAKEOS_LATEST_JSON_AOSP}" | jq -r ".${DEVICE}.branch")
    if [ -z "$AOSP_BRANCH" ]; then
      echo "ERROR: Unable to get latest AOSP branch details. Stopping build."
      exit 1
    fi
  fi
  echo "AOSP_BRANCH=${AOSP_BRANCH}"

}

check_for_new_versions() {
  log_header ${FUNCNAME}

  echo "Checking if any new versions of software exist"
  needs_update=false


  # check aosp
  existing_aosp_build=$(cat $CHAOSP_DIR/revisions/${DEVICE}-vendor || true)
  if [ "$existing_aosp_build" == "$AOSP_VENDOR_BUILD" ]; then
    echo "AOSP build ($existing_aosp_build) is up to date"
  else
    echo "AOSP needs to be updated to ${AOSP_VENDOR_BUILD}"
    needs_update=true
    BUILD_REASON="$BUILD_REASON 'AOSP build $existing_aosp_build != $AOSP_VENDOR_BUILD'"
  fi

  # check chromium
  if [ ! -z "$CHROMIUM_PINNED_VERSION" ]; then
    log "Setting LATEST_CHROMIUM to pinned version $CHROMIUM_PINNED_VERSION"
    LATEST_CHROMIUM="$CHROMIUM_PINNED_VERSION"
  fi
  existing_chromium=$(cat $CHAOSP_DIR/chromium/revision || true)
  chromium_included=$(cat $CHAOSP_DIR/chromium/included || true)
  if [ "$existing_chromium" == "$LATEST_CHROMIUM" ] && [ "$chromium_included" == "yes" ]; then
    echo "Chromium build ($existing_chromium) is up to date"
  else
    echo "Chromium needs to be updated to ${LATEST_CHROMIUM}"
    echo "no" > $CHAOSP_DIR/chromium/included
    needs_update=true
    if [ "$existing_chromium" == "$LATEST_CHROMIUM" ]; then
      BUILD_REASON="$BUILD_REASON 'Chromium version $existing_chromium built but not installed'"
    else
      BUILD_REASON="$BUILD_REASON 'Chromium version $existing_chromium != $LATEST_CHROMIUM'"
    fi
  fi

  # check fdroid
  existing_fdroid_client=$(cat $CHAOSP_DIR/revisions/fdroid/revision || true)
  if [ "$existing_fdroid_client" == "$FDROID_CLIENT_VERSION" ]; then
    echo "F-Droid build ($existing_fdroid_client) is up to date"
  else
    echo "F-Droid needs to be updated to ${FDROID_CLIENT_VERSION}"
    needs_update=true
    BUILD_REASON="$BUILD_REASON 'F-Droid version $existing_fdroid_client != $FDROID_CLIENT_VERSION'"
  fi

  # check fdroid priv extension
  existing_fdroid_priv_version=$(cat $CHAOSP_DIR/revisions/fdroid-priv/revision || true)
  if [ "$existing_fdroid_priv_version" == "$FDROID_PRIV_EXT_VERSION" ]; then
    echo "F-Droid privileged extension build ($existing_fdroid_priv_version) is up to date"
  else
    echo "F-Droid privileged extension needs to be updated to ${FDROID_PRIV_EXT_VERSION}"
    needs_update=true
    BUILD_REASON="$BUILD_REASON 'F-Droid privileged extension $existing_fdroid_priv_version != $FDROID_PRIV_EXT_VERSION'"
  fi

  if [ "$needs_update" = true ]; then
    echo "New build is required"
  else
    if [ "$FORCE_BUILD" = true ]; then
      message="No build is required, but FORCE_BUILD=true"
      echo "$message"
      BUILD_REASON="$message"
    elif [ "$IGNORE_VERSION_CHECKS" = true ]; then
      message="No build is required, but IGNORE_VERSION_CHECKS=true"
      echo "$message"
      BUILD_REASON="$message"
    else
      echo "CHAOSP build not required as all components are already up to date."
      exit 0
    fi
  fi

  if [ -z "$existing_stack_version" ]; then
    BUILD_REASON="Initial build"
  fi
}

full_run() {
  log_header ${FUNCNAME}

  revert_previous_run_patches

  get_latest_versions
  check_for_new_versions
  initial_key_setup
  echo "CHAOSP Build STARTED"
  setup_env
  check_chromium
  aosp_repo_init
  aosp_repo_modifications
  aosp_repo_sync
  gen_keys
  setup_vendor
  build_fdroid
  apply_patches
  # only marlin and sailfish need kernel rebuilt so that verity_key is included
  # Also build the kernel if enabled in the config 
  if [ "${KERNEL_FAMILY}" == "marlin" ] || [ "${ENABLE_KERNEL_BUILD}" == "true" ]; then
    rebuild_kernel
  fi
  add_chromium
  build_aosp

  if [ "$ADD_MAGISK" = true ]; then
    add_magisk
  fi

  release "${DEVICE}"
  checkpoint_versions
  echo "CHAOSP Build SUCCESS"
}

add_chromium() {
  log_header ${FUNCNAME}

  # replace AOSP webview with latest built chromium webview
  cp "$CHAOSP_DIR/SystemWebView.apk" ${BUILD_DIR}/external/chromium-webview/prebuilt/arm64/webview.apk

  # add latest built chromium browser to external/chromium
  cp "$CHAOSP_DIR/ChromeModernPublic.apk" ${BUILD_DIR}/external/chromium/prebuilt/arm64/
}

build_fdroid() {
  log_header ${FUNCNAME}

  # build it outside AOSP build tree or hit errors
  git clone https://gitlab.com/fdroid/fdroidclient ${CHAOSP_DIR}/fdroidclient
  pushd ${CHAOSP_DIR}/fdroidclient
  echo "sdk.dir=${CHAOSP_DIR}/sdk" > local.properties
  echo "sdk.dir=${CHAOSP_DIR}/sdk" > app/local.properties
  git checkout $FDROID_CLIENT_VERSION
  retry ./gradlew assembleRelease
  cp -f app/build/outputs/apk/full/release/app-full-release-unsigned.apk ${BUILD_DIR}/packages/apps/F-Droid/F-Droid.apk
  echo -ne "$FDROID_CLIENT_VERSION" > ${CHAOSP_DIR}/revisions/fdroid/revision
  popd
  rm -rf ${CHAOSP_DIR}/fdroidclient
}

get_encryption_key() {
  additional_message=""
  if [ "$(ls CHAOSP_DIR/${DEVICE} | wc -l)" == '0' ]; then
    additional_message="Since you have no encrypted signing keys in $CHAOSP_DIR/${DEVICE} yet - new signing keys will be generated and encrypted with provided passphrase."
  fi

  wait_time="10m"
  error_message=""
  while [ 1 ]; do
    # aws sns publish --region ${REGION} --topic-arn "$AWS_SNS_ARN" \
    #   --message="$(printf "%s Need to login to the EC2 instance and provide the encryption passphrase (${wait_time} timeout before shutdown). You may need to open up SSH in the default security group, see the FAQ for details. %s\n\nssh ubuntu@%s 'printf \"Enter encryption passphrase: \" && read -s k && echo \"\$k\" > %s'" "$error_message" "$additional_message" "${INSTANCE_IP}" "${ENCRYPTION_PIPE}")"
    # error_message=""

    log "Waiting for encryption passphrase (with $wait_time timeout) to be provided over named pipe $ENCRYPTION_PIPE"
    set +e
    ENCRYPTION_KEY=$(timeout $wait_time cat $ENCRYPTION_PIPE)
    if [ $? -ne 0 ]; then
      set -e
      log "Timeout ($wait_time) waiting for encryption passphrase"
      echo "Timeout ($wait_time) waiting for encryption passphrase. Terminating build process."
      exit 1
    fi
    set -e
    if [ -z "$ENCRYPTION_KEY" ]; then
      error_message="ERROR: Empty encryption passphrase received - try again."
      log "$error_message"
      continue
    fi
    log "Received encryption passphrase over named pipe $ENCRYPTION_PIPE"

    if [ "$(ls $CHAOSP_DIR/${DEVICE} | wc -l)" == '0' ]; then
      log "No existing encrypting keys - new keys will be generated later in build process."
    else
      log "Verifying encryption passphrase is valid by syncing encrypted signing keys from S3 and decrypting"
      #aws s3 sync "s3://${AWS_ENCRYPTED_KEYS_BUCKET}" "${KEYS_DIR}"

      decryption_error=false
      set +e
      for f in $(find "${KEYS_DIR}" -type f -name '*.gpg'); do
        output_file=$(echo $f | awk -F".gpg" '{print $1}')
        log "Decrypting $f to ${output_file}..."
        gpg -d --batch --passphrase "${ENCRYPTION_KEY}" $f > $output_file
        if [ $? -ne 0 ]; then
          log "Failed to decrypt $f"
          decryption_error=true
        fi
      done
      set -e
      if [ "$decryption_error" = true ]; then
        log
        error_message="ERROR: Failed to decrypt signing keys with provided passphrase - try again."
        log "$error_message"
        continue
      fi
    fi
    break
  done
}

initial_key_setup() {
  # setup in memory file system to hold keys
  log "Mounting in memory filesystem at ${KEYS_DIR} to hold keys"
  mkdir -p $KEYS_DIR
  sudo mount -t tmpfs -o size=20m tmpfs $KEYS_DIR || true

  # additional steps for getting encryption key up front
  if [ "$ENCRYPTED_KEYS" = true ]; then
    log "Encrypted keys option was specified"

    # send warning if user has selected encrypted keys option but still has normal keys
    if [ "$(ls $CHAOSP_DIR/${DEVICE} | wc -l)" != '0' ]; then
      if [ "$(ls $CHAOSP_DIR/${DEVICE} | wc -l)" == '0' ]; then
        echo "It looks like you have selected --encrypted-keys option and have existing signing keys in s3://${AWS_KEYS_BUCKET}/${DEVICE} but you haven't migrated your keys to s3://${AWS_ENCRYPTED_KEYS_BUCKET}/${DEVICE}. This means new encrypted signing keys will be generated and you'll need to flash a new factory image on your device. If you want to keep your existing keys - cancel this build and follow the steps on migrating your keys in the FAQ."
      fi
    fi

    # sudo apt-get -y install gpg
    if [ ! -e "$ENCRYPTION_PIPE" ]; then
      mkfifo $ENCRYPTION_PIPE
    fi

    get_encryption_key
  fi
}

setup_env() {
  log_header ${FUNCNAME}

  # setup build dir
  mkdir -p "$BUILD_DIR"

  # setup android sdk (required for fdroid build)
  if [ ! -f "${CHAOSP_DIR}/sdk/tools/bin/sdkmanager" ]; then
    mkdir -p ${CHAOSP_DIR}/sdk
    cd ${CHAOSP_DIR}/sdk
    retry wget ${ANDROID_SDK_URL} -O sdk-tools.zip
    unzip sdk-tools.zip
    yes | ./tools/bin/sdkmanager --licenses
    ./tools/android update sdk -u --use-sdk-wrapper
    # workaround for license issue with f-droid using older sdk (didn't spend time to debug issue further)
    yes | ./tools/bin/sdkmanager "build-tools;27.0.3" "platforms;android-27"
  fi

  # setup git
  git config --get --global user.name || git config --global user.name 'unknown'
  git config --get --global user.email || git config --global user.email 'unknown@localhost'
  git config --global color.ui true
}

check_chromium() {
  log_header ${FUNCNAME}

  current=$(cat $CHAOSP_DIR/chromium/revision || true)
  log "Chromium current: $current"

  log "Chromium latest: $LATEST_CHROMIUM"
  if [ "$LATEST_CHROMIUM" == "$current" ]; then
    log "Chromium latest ($LATEST_CHROMIUM) matches current ($current) - just copying chromium artifact"
    cp $CHAOSP_DIR/SystemWebView.apk ${BUILD_DIR}/external/chromium-webview/prebuilt/arm64/webview.apk
    cp $CHAOSP_DIR/ChromeModernPublic.apk ${BUILD_DIR}/external/chromium/prebuilt/arm64/
  else
    log "Building chromium $LATEST_CHROMIUM"
    build_chromium $LATEST_CHROMIUM
  fi
  #rm -rf $CHAOSP_DIR/chromium
}

build_chromium() {
  log_header ${FUNCNAME}

  CHROMIUM_REVISION=$1
  DEFAULT_VERSION=$(echo $CHROMIUM_REVISION | awk -F"." '{ printf "%s%03d52\n",$3,$4}')

  # depot tools setup
  if [ ! -d "$CHAOSP_DIR/depot_tools" ]; then
    retry git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $CHAOSP_DIR/depot_tools
  fi
  export PATH="$PATH:$CHAOSP_DIR/depot_tools"

  # fetch chromium
  mkdir -p $CHAOSP_DIR/chromium
  cd $CHAOSP_DIR/chromium
  # Fallback when updating chromium source after an previous fetch
  fetch --nohooks android || gclient sync -D --with_branch_heads --with_tags --jobs 32 -RDf && cd src && git fetch && cd -
  cd src

  # checkout specific revision
  git checkout "$CHROMIUM_REVISION" -f

  # install dependencies
  echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
  log "Installing chromium build dependencies"
  sudo ./build/install-build-deps-android.sh

  # run gclient sync (runhooks will run as part of this)
  log "Running gclient sync (this takes a while)"
  for i in {1..5}; do
    yes | gclient sync --with_branch_heads --jobs 32 -RDf && break
  done

  # cleanup any files in tree not part of this revision
  git clean -dff

  # reset any modifications
  git checkout -- .

  # generate configuration
  mkdir -p out/Default
  cat <<EOF > out/Default/args.gn
target_os = "android"
target_cpu = "arm64"
is_debug = false
is_official_build = true
is_component_build = false
symbol_level = 1
ffmpeg_branding = "Chrome"
proprietary_codecs = true
android_channel = "stable"
android_default_version_name = "$CHROMIUM_REVISION"
android_default_version_code = "$DEFAULT_VERSION"
EOF
  gn gen out/Default

  log "Building chromium chrome_modern_public_apk target"
  autoninja -C out/Default/ chrome_modern_public_apk

  log "Building chromium system_webview_apk target"
  autoninja -C out/Default/ system_webview_apk

  # copy to build tree
  mkdir -p ${BUILD_DIR}/external/chromium/prebuilt/arm64
  cp "out/Default/apks/SystemWebView.apk" ${BUILD_DIR}/external/chromium-webview/prebuilt/arm64/webview.apk
  cp "out/Default/apks/ChromeModernPublic.apk" ${BUILD_DIR}/external/chromium/prebuilt/arm64/
  # copy this apk outside of chromium folder, in case of
  cp "out/Default/apks/SystemWebView.apk" $CHAOSP_DIR/
  cp "out/Default/apks/ChromeModernPublic.apk" $CHAOSP_DIR/

  # upload to s3 for future builds
  echo "${CHROMIUM_REVISION}" > $CHAOSP_DIR/chromium/revision
}

aosp_repo_init() {
  log_header ${FUNCNAME}
  cd "${BUILD_DIR}"

  retry repo init --manifest-url "$MANIFEST_URL" --manifest-branch "$AOSP_BRANCH" --depth 1 || true
}

aosp_repo_modifications() {
  log_header ${FUNCNAME}
  cd "${BUILD_DIR}"

  mkdir -p ${BUILD_DIR}/.repo/local_manifests

  cat <<EOF > ${BUILD_DIR}/.repo/local_manifests/rattlesnakeos.xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="github" fetch="https://github.com/RattlesnakeOS/" revision="${ANDROID_VERSION}" />
  <remote name="fdroid" fetch="https://gitlab.com/fdroid/" />
  <remote name="prepare-vendor" fetch="https://github.com/AOSPAlliance/" revision="android10" />  
  <remote name="opengapps" fetch="https://github.com/opengapps/" />
  <remote name="opengapps-gitlab" fetch="https://gitlab.opengapps.org/opengapps/" />


  <project path="vendor/opengapps/build" name="aosp_build" revision="master" remote="opengapps" />
  <project path="vendor/opengapps/sources/all" name="all" clone-depth="1" revision="master" remote="opengapps-gitlab" />
  <project path="vendor/opengapps/sources/arm" name="arm" clone-depth="1" revision="master" remote="opengapps-gitlab" />
  <project path="vendor/opengapps/sources/arm64" name="arm64" clone-depth="1" revision="master" remote="opengapps-gitlab" />

  <project path="external/chromium" name="platform_external_chromium" remote="github" />
  <project path="packages/apps/Updater" name="platform_packages_apps_Updater" remote="github" />
  <project path="packages/apps/F-Droid" name="platform_external_fdroid" remote="github" />
  <project path="packages/apps/F-DroidPrivilegedExtension" name="privileged-extension" remote="fdroid" revision="refs/tags/${FDROID_PRIV_EXT_VERSION}" />
  <project path="vendor/android-prepare-vendor" name="android-prepare-vendor" remote="prepare-vendor" />

  <remove-project name="platform/packages/apps/Browser2" />
  <remove-project name="platform/packages/apps/Calendar" />
  <remove-project name="platform/packages/apps/QuickSearchBox" />

</manifest>
EOF

}

aosp_repo_sync() {
  log_header ${FUNCNAME}
  cd "${BUILD_DIR}"

  # sync with retries
  for i in {1..10}; do
    repo sync -c --no-tags --no-clone-bundle --jobs 32 && break
  done

  cd vendor/opengapps/sources/
  cd all
  git lfs pull
  cd -
  cd arm
  git lfs pull
  cd -
  cd arm64
  git lfs pull
}

setup_vendor() {
  log_header ${FUNCNAME}

  # get vendor files (with timeout)
  timeout 30m "${BUILD_DIR}/vendor/android-prepare-vendor/execute-all.sh" --full --debugfs --keep --yes --device "${DEVICE}" --buildID "${AOSP_VENDOR_BUILD}" -i "${BUILD_DIR}/vendor/android-prepare-vendor/${DEVICE}/${AOSP_VENDOR_DIR}/sargo-qq3a.200805.001-factory-a1d05d06.zip" -O "${BUILD_DIR}/vendor/android-prepare-vendor/${DEVICE}/${AOSP_VENDOR_DIR}/sargo-ota-qq3a.200805.001-de147438.zip" --output "${BUILD_DIR}/vendor/android-prepare-vendor"
  echo "${AOSP_BUILD}" > "$CHAOSP_DIR/revisions/${DEVICE}-vendor"

  # copy vendor files to build tree
  mkdir --parents "${BUILD_DIR}/vendor/google_devices" || true
  rm -rf "${BUILD_DIR}/vendor/google_devices/$DEVICE" || true
  mv "${BUILD_DIR}/vendor/android-prepare-vendor/${DEVICE}/$(tr '[:upper:]' '[:lower:]' <<< "${AOSP_VENDOR_BUILD}")/vendor/google_devices/${DEVICE}" "${BUILD_DIR}/vendor/google_devices"

  # smaller devices need big brother vendor files
  if [ "$DEVICE" != "$DEVICE_FAMILY" ]; then
    rm -rf "${BUILD_DIR}/vendor/google_devices/$DEVICE_FAMILY" || true
    mv "${BUILD_DIR}/vendor/android-prepare-vendor/$DEVICE/$(tr '[:upper:]' '[:lower:]' <<< "${AOSP_VENDOR_BUILD}")/vendor/google_devices/$DEVICE_FAMILY" "${BUILD_DIR}/vendor/google_devices"
  fi
}

apply_patches() {
  log_header ${FUNCNAME}

  revert_previous_run_patches
  patch_mkbootfs
  patch_recovery
  patch_add_opengapps
  #patch_custom
  patch_aosp_removals
  patch_add_apps
  #patch_tethering
  patch_base_config
  patch_settings_app
  patch_device_config
  patch_updater
  patch_priv_ext
  patch_launcher
  patch_broken_alarmclock
  patch_broken_messaging
  patch_disable_apex
}

# currently don't have a need for apex updates (https://source.android.com/devices/tech/ota/apex)
patch_disable_apex() {
  log_header ${FUNCNAME}

  # pixel 1 devices do not support apex so nothing to patch
  # pixel 2 devices opt in here
  sed -i 's@$(call inherit-product, $(SRC_TARGET_DIR)/product/updatable_apex.mk)@@' ${BUILD_DIR}/device/google/wahoo/device.mk
  # all other devices use mainline and opt in here
  sed -i 's@$(call inherit-product, $(SRC_TARGET_DIR)/product/updatable_apex.mk)@@' ${BUILD_DIR}/build/make/target/product/mainline_system.mk
}

# TODO: remove once this once fix from upstream makes it into release branch
# https://android.googlesource.com/platform/packages/apps/DeskClock/+/e6351b3b85b2f5d53d43e4797d3346ce22a5fa6f%5E%21/
patch_broken_alarmclock() {
  log_header ${FUNCNAME}

  if ! grep -q "android.permission.FOREGROUND_SERVICE" ${BUILD_DIR}/packages/apps/DeskClock/AndroidManifest.xml; then
    sed -i '/<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" \/>/a <uses-permission android:name="android.permission.FOREGROUND_SERVICE" \/>' ${BUILD_DIR}/packages/apps/DeskClock/AndroidManifest.xml
    sed -i 's@<uses-sdk android:minSdkVersion="19" android:targetSdkVersion="28" />@<uses-sdk android:minSdkVersion="19" android:targetSdkVersion="25" />@' ${BUILD_DIR}/packages/apps/DeskClock/AndroidManifest.xml
  fi
}

# TODO: remove once this once fix from upstream makes it into release branch
# https://android.googlesource.com/platform/packages/apps/Messaging/+/8e71d1b707123e1b48b5529b1661d53762922400%5E%21/
patch_broken_messaging() {
  log_header ${FUNCNAME}

  if ! grep -q "android:targetSdkVersion=\"24\"" ${BUILD_DIR}/packages/apps/Messaging/AndroidManifest.xml; then
    sed -i 's@<uses-sdk android:minSdkVersion="19" android:targetSdkVersion="28" />@<uses-sdk android:minSdkVersion="19" android:targetSdkVersion="24" />@' ${BUILD_DIR}/packages/apps/Messaging/AndroidManifest.xml
  fi
}

# This patch is needed to be able to add "." prefixed files/folders (like ".backup" and ".magisk") from Magisk, into the boot image
patch_mkbootfs(){
  cd $BUILD_DIR/system/core/
  patch -p1 --no-backup-if-mismatch < ${CHAOSP_DIR}/patches/0004_allow_dot_files_in_ramdisk.patch
}

patch_recovery(){
  cd $BUILD_DIR/bootable/recovery/
  patch -p1 --no-backup-if-mismatch < ${CHAOSP_DIR}/patches/0002_recovery_add_mark_successful_option.patch
}

# This patch is needed to make opengapps included/called during the build phase
patch_add_opengapps(){
  cd $BUILD_DIR/device/google/$DEVICE_FAMILY/
  sed -i "s/# PRODUCT_RESTRICT_VENDOR_FILES := all/PRODUCT_RESTRICT_VENDOR_FILES := false/g" aosp_$DEVICE.mk
  sed -i "/# limitations under the License./a GAPPS_VARIANT := pico" device.mk
  echo -ne "\\n\$(call inherit-product, vendor/opengapps/build/opengapps-packages.mk)" >> device.mk
}

patch_aosp_removals() {
  log_header ${FUNCNAME}

  # remove aosp chromium webview directory
  #rm -rf ${BUILD_DIR}/platform/external/chromium-webview

  # loop over all make files as these keep changing and remove components
  for mk_file in ${BUILD_DIR}/build/make/target/product/*.mk; do
    # remove aosp webview
    #sed -i '/webview \\/d' ${mk_file}

    # remove Browser2
    sed -i '/Browser2/d' ${mk_file}

    # remove Calendar
    sed -i '/Calendar \\/d' ${mk_file}
    sed -i '/Calendar.apk/d' ${mk_file}

    # remove QuickSearchBox
    sed -i '/QuickSearchBox/d' ${mk_file}
  done

}

revert_previous_run_patches() {
  log_header ${FUNCNAME}

  if [ -d $BUILD_DIR ]; then
    cd $BUILD_DIR

    #repo sync -d
    repo forall -vc "git reset --hard" || true
    rm -f $BUILD_DIR/bootable/recovery/install/{include/install/mark_slot_successful.h,mark_slot_successful.cpp}
  fi

}

# TODO: most of this is fragile and unforgiving
patch_custom() {
  log_header ${FUNCNAME}

  cd $BUILD_DIR

  # # allow custom patches to be applied
  patches_dir="$CHAOSP_DIR/patches"
  # <% if .CustomPatches %>
  # <% range $i, $r := .CustomPatches %>
  #   retry git clone <% $r.Repo %> ${patches_dir}/<% $i %>
  #   <% range $r.Patches %>
  #     log "Applying patch <% . %>"
  #     patch -p1 --no-backup-if-mismatch < ${patches_dir}/<% $i %>/<% . %>
  #   <% end %>
  # <% end %>
  # <% end %>

  # if [ ! -d ${patches_dir}/microg ]; then
  #   retry git clone "https://github.com/RattlesnakeOS/microg" ${patches_dir}/microg
  # fi
  # log "Applying patch 00002-microg-sigspoof.patch"
  # patch -p1 --no-backup-if-mismatch < ${patches_dir}/microg/00002-microg-sigspoof.patch

  if [ ! -d ${patches_dir}/community_patches ]; then
    retry git clone https://github.com/RattlesnakeOS/community_patches ${patches_dir}/community_patches
  fi
 
  log "Applying patch 00001-global-internet-permission-toggle.patch"
  patch -p1 --no-backup-if-mismatch < ${patches_dir}/community_patches/00001-global-internet-permission-toggle.patch

  log "Applying patch 00002-global-sensors-permission-toggle.patch"
  patch -p1 --no-backup-if-mismatch < ${patches_dir}/community_patches/00002-global-sensors-permission-toggle.patch

  log "Applying patch 00003-disable-menu-entries-in-recovery.patch"
  patch -p1 --no-backup-if-mismatch < ${patches_dir}/community_patches/00003-disable-menu-entries-in-recovery.patch

  log "Applying patch 00004-increase-default-maximum-password-length.patch"
  patch -p1 --no-backup-if-mismatch < ${patches_dir}/community_patches/00004-increase-default-maximum-password-length.patch


  # # allow custom scripts to be applied
  scripts_dir="$CHAOSP_DIR/scripts"
  # <% if .CustomScripts %>
  # <% range $i, $r := .CustomScripts %>
  #   retry git clone <% $r.Repo %> ${scripts_dir}/<% $i %>
  #   <% range $r.Scripts %>
  #     log "Applying shell script <% . %>"
  #     . ${scripts_dir}/<% $i %>/<% . %>
  #   <% end %>
  # <% end %>
  # <% end %>

  if [ ! -d ${scripts_dir}/example_patch_shellscript ]; then
    retry git clone "https://github.com/RattlesnakeOS/example_patch_shellscript" ${scripts_dir}/example_patch_shellscript || true
  fi
  log "Applying shell script 00002-custom-boot-animation.sh"
  . ${scripts_dir}/example_patch_shellscript/00002-custom-boot-animation.sh

  # # allow prebuilt applications to be added to build tree
  # prebuilt_dir="$BUILD_DIR/packages/apps/Custom"
  # <% if .CustomPrebuilts %>
  # <% range $i, $r := .CustomPrebuilts %>
  #   log "Putting custom prebuilts from <% $r.Repo %> in build tree location ${prebuilt_dir}/<% $i %>"
  #   retry git clone <% $r.Repo %> ${prebuilt_dir}/<% $i %>
  #   <% range .Modules %>
  #     log "Adding custom PRODUCT_PACKAGES += <% . %> to $(get_package_mk_file)"
  #     sed -i "\$aPRODUCT_PACKAGES += <% . %>" $(get_package_mk_file)
  #   <% end %>
  # <% end %>
  # <% end %>

  # log "Putting custom prebuilts from https://github.com/RattlesnakeOS/microg in build tree location ${prebuilt_dir}/microg"
  # if [ ! -d ${prebuilt_dir}/microg ]; then
  #   retry git clone https://github.com/RattlesnakeOS/microg ${prebuilt_dir}/microg
  # fi

  # log "Adding custom PRODUCT_PACKAGES += GmsCore to $(get_package_mk_file)"
  # sed -i "\$aPRODUCT_PACKAGES += GmsCore" $(get_package_mk_file)

  # log "Adding custom PRODUCT_PACKAGES += GsfProxy to $(get_package_mk_file)"
  # sed -i "\$aPRODUCT_PACKAGES += GsfProxy" $(get_package_mk_file)

  # log "Adding custom PRODUCT_PACKAGES += FakeStore to $(get_package_mk_file)"
  # sed -i "\$aPRODUCT_PACKAGES += FakeStore" $(get_package_mk_file)

  # log "Adding custom PRODUCT_PACKAGES += com.google.android.maps.jar to $(get_package_mk_file)"
  # sed -i "\$aPRODUCT_PACKAGES += com.google.android.maps.jar" $(get_package_mk_file)


  # allow custom hosts file
  hosts_file_location="$BUILD_DIR/system/core/rootdir/etc/hosts"
  if [ -z "$HOSTS_FILE" ]; then
    log "No custom hosts file requested"
  else
    log "Replacing hosts file with $HOSTS_FILE"
    retry wget -O $hosts_file_location "$HOSTS_FILE"
  fi
}

patch_base_config() {
  log_header ${FUNCNAME}

  # enable swipe up gesture functionality as option
  sed -i 's@<bool name="config_swipe_up_gesture_setting_available">false</bool>@<bool name="config_swipe_up_gesture_setting_available">true</bool>@' ${BUILD_DIR}/frameworks/base/core/res/res/values/config.xml

  # enable doze and app standby
  sed -i 's@<bool name="config_enableAutoPowerModes">false</bool>@<bool name="config_enableAutoPowerModes">true</bool>@' ${BUILD_DIR}/frameworks/base/core/res/res/values/config.xml
}

patch_settings_app() {
  log_header ${FUNCNAME}

  # fix for cards not disappearing in settings app
  sed -i 's@<bool name="config_use_legacy_suggestion">true</bool>@<bool name="config_use_legacy_suggestion">false</bool>@' ${BUILD_DIR}/packages/apps/Settings/res/values/config.xml
}

patch_device_config() {
  log_header ${FUNCNAME}

  # set proper model names
  sed -i 's@PRODUCT_MODEL := AOSP on msm8996@PRODUCT_MODEL := Pixel XL@' ${BUILD_DIR}/device/google/marlin/aosp_marlin.mk
  sed -i 's@PRODUCT_MANUFACTURER := google@PRODUCT_MANUFACTURER := Google@' ${BUILD_DIR}/device/google/marlin/aosp_marlin.mk
  sed -i 's@PRODUCT_MODEL := AOSP on msm8996@PRODUCT_MODEL := Pixel@' ${BUILD_DIR}/device/google/marlin/aosp_sailfish.mk
  sed -i 's@PRODUCT_MANUFACTURER := google@PRODUCT_MANUFACTURER := Google@' ${BUILD_DIR}/device/google/marlin/aosp_sailfish.mk

  sed -i 's@PRODUCT_MODEL := AOSP on taimen@PRODUCT_MODEL := Pixel 2 XL@' ${BUILD_DIR}/device/google/taimen/aosp_taimen.mk
  sed -i 's@PRODUCT_MODEL := AOSP on walleye@PRODUCT_MODEL := Pixel 2@' ${BUILD_DIR}/device/google/muskie/aosp_walleye.mk

  sed -i 's@PRODUCT_MODEL := AOSP on crosshatch@PRODUCT_MODEL := Pixel 3 XL@' ${BUILD_DIR}/device/google/crosshatch/aosp_crosshatch.mk || true
  sed -i 's@PRODUCT_MODEL := AOSP on blueline@PRODUCT_MODEL := Pixel 3@' ${BUILD_DIR}/device/google/crosshatch/aosp_blueline.mk || true

  sed -i 's@PRODUCT_MODEL := AOSP on bonito@PRODUCT_MODEL := Pixel 3a XL@' ${BUILD_DIR}/device/google/bonito/aosp_bonito.mk || true
  sed -i 's@PRODUCT_MODEL := AOSP on sargo@PRODUCT_MODEL := Pixel 3a@' ${BUILD_DIR}/device/google/bonito/aosp_sargo.mk || true

  sed -i 's@PRODUCT_MODEL := AOSP on coral@PRODUCT_MODEL := Pixel 4 XL@' ${BUILD_DIR}/device/google/coral/aosp_coral.mk || true
  sed -i 's@PRODUCT_MODEL := AOSP on flame@PRODUCT_MODEL := Pixel 4@' ${BUILD_DIR}/device/google/coral/aosp_flame.mk || true

  sed -i 's@PRODUCT_MODEL := AOSP on sunfish@PRODUCT_MODEL := Pixel 4A@' ${BUILD_DIR}/device/google/sunfish/aosp_sunfish.mk || true
}

get_package_mk_file() {
  mk_file=${BUILD_DIR}/build/make/target/product/handheld_system.mk
  if [ ! -f ${mk_file} ]; then
    log "Expected handheld_system.mk or core.mk do not exist"
    exit 1
  fi
  echo ${mk_file}
}

patch_add_apps() {
  log_header ${FUNCNAME}

  mk_file=$(get_package_mk_file)
  sed -i "\$aPRODUCT_PACKAGES += Updater" ${mk_file}
  sed -i "\$aPRODUCT_PACKAGES += F-DroidPrivilegedExtension" ${mk_file}
  sed -i "\$aPRODUCT_PACKAGES += F-Droid" ${mk_file}
  sed -i "\$aPRODUCT_PACKAGES += chromium" ${mk_file}

  # # add any modules defined in custom manifest projects
  # <% if .CustomManifestProjects %><% range $i, $r := .CustomManifestProjects %><% range $j, $q := .Modules %>
  # log "Adding custom PRODUCT_PACKAGES += <% $q %> to ${mk_file}"
  # sed -i "\$aPRODUCT_PACKAGES += <% $q %>" ${mk_file}
  # <% end %>
  # <% end %>
  # <% end %>
}

patch_tethering() {
  # TODO: probably could do these edits in a cleaner way
  sed -i "\$aPRODUCT_PROPERTY_OVERRIDES += net.tethering.noprovisioning=true" $(get_package_mk_file)
  awk -i inplace '1;/def_vibrate_when_ringing/{print "    <integer name=\"def_tether_dun_required\">0</integer>";}' ${BUILD_DIR}/frameworks/base/packages/SettingsProvider/res/values/defaults.xml
  awk -i inplace '1;/loadSetting\(stmt, Settings.Global.PREFERRED_NETWORK_MODE/{print "            loadSetting(stmt, Settings.Global.TETHER_DUN_REQUIRED, R.integer.def_tether_dun_required);";}' ${BUILD_DIR}/frameworks/base/packages/SettingsProvider/src/com/android/providers/settings/DatabaseHelper.java
}

patch_updater() {
  log_header ${FUNCNAME}

  cd "$BUILD_DIR"/packages/apps/Updater/res/values
  sed --in-place --expression "s@s3bucket@${RELEASE_URL}/@g" config.xml
}

fdpe_hash() {
  keytool -list -printcert -file "$1" | grep 'SHA256:' | tr --delete ':' | cut --delimiter ' ' --fields 3
}

patch_priv_ext() {
  log_header ${FUNCNAME}

  # 0.2.9 added whitelabel support, so BuildConfig.APPLICATION_ID needs to be set now
  sed -i 's@BuildConfig.APPLICATION_ID@"org.fdroid.fdroid.privileged"@' ${BUILD_DIR}/packages/apps/F-DroidPrivilegedExtension/app/src/main/java/org/fdroid/fdroid/privileged/PrivilegedService.java

  unofficial_releasekey_hash=$(fdpe_hash "${KEYS_DIR}/${DEVICE}/releasekey.x509.pem")
  unofficial_platform_hash=$(fdpe_hash "${KEYS_DIR}/${DEVICE}/platform.x509.pem")
  sed -i 's/'${OFFICIAL_FDROID_KEY}'")/'${unofficial_releasekey_hash}'"),\n            new Pair<>("org.fdroid.fdroid", "'${unofficial_platform_hash}'")/' \
      "${BUILD_DIR}/packages/apps/F-DroidPrivilegedExtension/app/src/main/java/org/fdroid/fdroid/privileged/ClientWhitelist.java"
}

patch_launcher() {
  log_header ${FUNCNAME}

  # disable QuickSearchBox widget on home screen
  sed -i.original "s/QSB_ON_FIRST_SCREEN = true;/QSB_ON_FIRST_SCREEN = false;/" "${BUILD_DIR}/packages/apps/Launcher3/src/com/android/launcher3/config/BaseFlags.java"
  # fix compile error with uninitialized variable
  sed -i.original "s/boolean createEmptyRowOnFirstScreen;/boolean createEmptyRowOnFirstScreen = false;/" "${BUILD_DIR}/packages/apps/Launcher3/src/com/android/launcher3/provider/ImportDataTask.java"
}

rebuild_kernel() {
  log_header ${FUNCNAME}

  # checkout kernel source on proper commit
  mkdir -p "${KERNEL_SOURCE_DIR}"
  retry git clone "${KERNEL_SOURCE_URL}" "${KERNEL_SOURCE_DIR}"
  
  if [ "${KERNEL_FAMILY}" == "marlin" ] || [ "${KERNEL_FAMILY}" == "wahoo" ]; then
    kernel_image="${BUILD_DIR}/device/google/${KERNEL_FAMILY}-kernel/Image.lz4-dtb"
  else
    kernel_image="${BUILD_DIR}/device/google/${KERNEL_FAMILY}-kernel/Image.lz4"
  fi

  # TODO: make this a bit more robust
  kernel_commit_id=$(lz4cat "${kernel_image}" | strings | grep -a 'Linux version [0-9]' | cut -d ' ' -f3 | cut -d'-' -f2 | sed 's/^g//g')
  cd "${KERNEL_SOURCE_DIR}"
  log "Checking out kernel commit ${kernel_commit_id}"
  git checkout ${kernel_commit_id}

  # TODO: kernel patch hooks should be added here 

  # run in another shell to avoid it mucking with environment variables for normal AOSP build
  (
      set -e;
      export PATH="${BUILD_DIR}/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin:${PATH}";
      export PATH="${BUILD_DIR}/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin:${PATH}";
      export PATH="${BUILD_DIR}/prebuilts/misc/linux-x86/lz4:${PATH}";
      export PATH="${BUILD_DIR}/prebuilts/misc/linux-x86/dtc:${PATH}";
      export PATH="${BUILD_DIR}/prebuilts/misc/linux-x86/libufdt:${PATH}";
      cd ${KERNEL_SOURCE_DIR};

      if [ "${KERNEL_FAMILY}" == "marlin" ]; then
        ln --verbose --symbolic ${KEYS_DIR}/${DEVICE}/verity_user.der.x509 ${KERNEL_SOURCE_DIR}/verity_user.der.x509;
        make O=out ARCH=arm64 ${KERNEL_DEFCONFIG}_defconfig;
        make -j$(nproc --all) \
          O=out \
          ARCH=arm64 \
          CROSS_COMPILE=aarch64-linux-android- \
          CROSS_COMPILE_ARM32=arm-linux-androideabi-
        
        cp -f out/arch/arm64/boot/Image.lz4-dtb ${BUILD_DIR}/device/google/${KERNEL_FAMILY}-kernel/;
      fi

      # TODO: haven't tested kernel build for coral
      if [ "${KERNEL_FAMILY}" == "wahoo" ] || [ "${KERNEL_FAMILY}" == "crosshatch" ] || [ "${KERNEL_FAMILY}" == "bonito" ] || [ "${KERNEL_FAMILY}" == "coral" ]; then
        export PATH="${BUILD_DIR}/prebuilts/clang/host/linux-x86/clang-r353983c/bin:${PATH}";
        export LD_LIBRARY_PATH="${BUILD_DIR}/prebuilts/clang/host/linux-x86/clang-r353983c/lib64:${LD_LIBRARY_PATH}";
        make O=out ARCH=arm64 ${KERNEL_DEFCONFIG}_defconfig;
        make -j$(nproc --all) \
          O=out \
          ARCH=arm64 \
          CC=clang \
          CLANG_TRIPLE=aarch64-linux-gnu- \
          CROSS_COMPILE=aarch64-linux-android- \
          CROSS_COMPILE_ARM32=arm-linux-androideabi-
        
        cp -f out/arch/arm64/boot/{dtbo.img,Image.lz4-dtb} ${BUILD_DIR}/device/google/${KERNEL_FAMILY}-kernel/;

        if [ "${KERNEL_FAMILY}" == "crosshatch" ]; then
          cp -f out/arch/arm64/boot/dts/qcom/{sdm845-v2.dtb,sdm845-v2.1.dtb} ${BUILD_DIR}/device/google/${KERNEL_FAMILY}-kernel/;
        fi

        if [ "${KERNEL_FAMILY}" == "bonito" ]; then
          cp -f out/arch/arm64/boot/dts/qcom/sdm670.dtb ${BUILD_DIR}/device/google/${KERNEL_FAMILY}-kernel/;
        fi
      
      fi
      
      rm -rf ${BUILD_DIR}/out/build_*;
  )
}

build_aosp() {
  log_header ${FUNCNAME}

  cd "$BUILD_DIR"

  if [ "${AOSP_BUILD}" != "${AOSP_VENDOR_BUILD}" ]; then
    log "WARNING: Requested AOSP build does not match upstream vendor files. These images may not be functional."
    log "Patching build_id to match ${AOSP_BUILD}"
    echo "${AOSP_BUILD}" > vendor/google_devices/${DEVICE}/build_id.txt
  fi

  ############################
  # from original setup.sh script
  ############################
  source build/envsetup.sh
  export LANG=C
  export _JAVA_OPTIONS=-XX:-UsePerfData
  export BUILD_NUMBER=$(cat out/build_number.txt 2>/dev/null || date --utc +%Y.%m.%d.%H)
  log "BUILD_NUMBER=$BUILD_NUMBER"
  export DISPLAY_BUILD_NUMBER=true
  chrt -b -p 0 $$

  ccache -M 100G

  choosecombo $BUILD_TARGET
  log "Running target-files-package"
  retry make -j $(nproc) target-files-package
  log "Running brillo_update_payload"
  retry make -j $(nproc) brillo_update_payload
}

get_radio_image() {
  grep -Po "require version-$1=\K.+" vendor/$2/vendor-board-info.txt | tr '[:upper:]' '[:lower:]'
}

release() {
  log_header ${FUNCNAME}

  cd "$BUILD_DIR"

  ############################
  # from original setup.sh script
  ############################
  source build/envsetup.sh
  export LANG=C
  export _JAVA_OPTIONS=-XX:-UsePerfData
  export BUILD_NUMBER=$(cat out/build_number.txt 2>/dev/null || date --utc +%Y.%m.%d.%H)
  log "BUILD_NUMBER=$BUILD_NUMBER"
  export DISPLAY_BUILD_NUMBER=true
  chrt -b -p 0 $$

  ############################
  # from original release.sh script
  ############################
  KEY_DIR=keys/$1
  OUT=out/release-$1-${BUILD_NUMBER}
  source device/common/clear-factory-images-variables.sh

  DEVICE=$1
  BOOTLOADER=$(get_radio_image bootloader google_devices/${DEVICE})
  RADIO=$(get_radio_image baseband google_devices/${DEVICE})
  PREFIX=aosp_
  BUILD=$BUILD_NUMBER
  VERSION=$(grep -Po "BUILD_ID=\K.+" build/core/build_id.mk | tr '[:upper:]' '[:lower:]')
  PRODUCT=${DEVICE}
  TARGET_FILES=$DEVICE-target_files-$BUILD.zip

  # make sure output directory exists
  mkdir -p $OUT

  # depending on device need verity key or avb key
  case "${AVB_MODE}" in
    verity_only)
      AVB_SWITCHES=(--replace_verity_public_key "$KEY_DIR/verity_key.pub"
                    --replace_verity_private_key "$KEY_DIR/verity"
                    --replace_verity_keyid "$KEY_DIR/verity.x509.pem")
      ;;
    vbmeta_simple)
      # Pixel 2: one vbmeta struct, no chaining
      AVB_SWITCHES=(--avb_vbmeta_key "$KEY_DIR/avb.pem"
                    --avb_vbmeta_algorithm SHA256_RSA2048)
      ;;
    vbmeta_chained)
      # Pixel 3: main vbmeta struct points to a chained vbmeta struct in system.img
      AVB_SWITCHES=(--avb_vbmeta_key "$KEY_DIR/avb.pem"
                    --avb_vbmeta_algorithm SHA256_RSA2048
                    --avb_system_key "$KEY_DIR/avb.pem"
                    --avb_system_algorithm SHA256_RSA2048)
      ;;
    vbmeta_chained_v2)
      AVB_SWITCHES=(--avb_vbmeta_key "$KEY_DIR/avb.pem"
                    --avb_vbmeta_algorithm SHA256_RSA2048
                    --avb_system_key "$KEY_DIR/avb.pem"
                    --avb_system_algorithm SHA256_RSA2048
                    --avb_vbmeta_system_key "$KEY_DIR/avb.pem"
                    --avb_vbmeta_system_algorithm SHA256_RSA2048)
      ;;
  esac

  export PATH=$BUILD_DIR/prebuilts/build-tools/linux-x86/bin:$PATH

  log "Running sign_target_files_apks"
  build/tools/releasetools/sign_target_files_apks -o -d "$KEY_DIR" -k "build/target/product/security/networkstack=${KEY_DIR}/networkstack" "${AVB_SWITCHES[@]}" \
    out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/$PREFIX$DEVICE-target_files-$BUILD_NUMBER.zip \
    $OUT/$TARGET_FILES

  log "Running ota_from_target_files"
  build/tools/releasetools/ota_from_target_files --block -k "$KEY_DIR/releasekey" "${EXTRA_OTA[@]}" $OUT/$TARGET_FILES \
      $OUT/$DEVICE-ota_update-$BUILD.zip

  log "Running img_from_target_files"
  sed -i 's/zipfile\.ZIP_DEFLATED/zipfile\.ZIP_STORED/' build/tools/releasetools/img_from_target_files.py
  build/tools/releasetools/img_from_target_files $OUT/$TARGET_FILES $OUT/$DEVICE-img-$BUILD.zip

  log "Running generate-factory-images"
  cd $OUT
  sed -i 's/zip -r/tar cvf/' ../../device/common/generate-factory-images-common.sh
  sed -i 's/factory\.zip/factory\.tar/' ../../device/common/generate-factory-images-common.sh
  sed -i '/^mv / d' ../../device/common/generate-factory-images-common.sh
  source ../../device/common/generate-factory-images-common.sh
  mv $DEVICE-$VERSION-factory.tar $DEVICE-factory-$BUILD_NUMBER.tar
  rm -f $DEVICE-factory-$BUILD_NUMBER.tar.xz

  log "Running compress of factory image with pxz"
  time pxz -v -T0 -9 -z $DEVICE-factory-$BUILD_NUMBER.tar
}


checkpoint_versions() {
  log_header ${FUNCNAME}

  # checkpoint f-droid
  echo -ne "${FDROID_PRIV_EXT_VERSION}" > $CHAOSP_DIR/revisions/fdroid-priv/revision
  echo -ne "${FDROID_CLIENT_VERSION}" > $CHAOSP_DIR/revisions/fdroid/revision

  # checkpoint aosp
  echo -ne "${AOSP_VENDOR_BUILD}" > $CHAOSP_DIR/revisions/${DEVICE}-vendor || true
  
  # checkpoint chromium
  echo "yes" > $CHAOSP_DIR/chromium/included
}


gen_keys() {
  log_header ${FUNCNAME}

  mkdir -p "${KEYS_DIR}/${DEVICE}"
  cd "${KEYS_DIR}/${DEVICE}"
  if [ -z "$(ls -A ${KEYS_DIR}/${DEVICE})" ]; then
    for key in {releasekey,platform,shared,media,networkstack,verity} ; do
      # make_key exits with unsuccessful code 1 instead of 0, need ! to negate
      ! "${BUILD_DIR}/development/tools/make_key" "$key" "$CERTIFICATE_SUBJECT"
    done

    if [ "${AVB_MODE}" == "verity_only" ]; then
      gen_verity_key "${DEVICE}"
    else
      gen_avb_key "${DEVICE}"
    fi
  else
    echo "${KEYS_DIR}/${DEVICE} folder not empty! Won't generate new keys!"
  fi
}

gen_avb_key() {
  log_header ${FUNCNAME}

  cd "$BUILD_DIR"
  openssl genrsa -out "${KEYS_DIR}/$1/avb.pem" 2048
  ${BUILD_DIR}/external/avb/avbtool extract_public_key --key "${KEYS_DIR}/$1/avb.pem" --output "${KEYS_DIR}/$1/avb_pkmd.bin"
}

gen_verity_key() {
  log_header ${FUNCNAME}
  cd "$BUILD_DIR"

  make -j 20 generate_verity_key
  "${BUILD_DIR}/out/host/linux-x86/bin/generate_verity_key" -convert "${KEYS_DIR}/$1/verity.x509.pem" "${KEYS_DIR}/$1/verity_key"
  make clobber
  openssl x509 -outform der -in "${KEYS_DIR}/$1/verity.x509.pem" -out "${KEYS_DIR}/$1/verity_user.der.x509"
}

log_header() {
  echo "=================================="
  echo "$(date "+%Y-%m-%d %H:%M:%S"): Running $1"
  echo "=================================="
}

log() {
  echo "$(date "+%Y-%m-%d %H:%M:%S"): $1"
}

retry() {
  set +e
  local max_attempts=${ATTEMPTS-3}
  local timeout=${TIMEOUT-1}
  local attempt=0
  local exitCode=0

  while [[ $attempt < $max_attempts ]]
  do
    "$@"
    exitCode=$?

    if [[ $exitCode == 0 ]]
    then
      break
    fi

    log "Failure! Retrying ($@) in $timeout.."
    sleep $timeout
    attempt=$(( attempt + 1 ))
    timeout=$(( timeout * 2 ))
  done

  if [[ $exitCode != 0 ]]
  then
    log "Failed too many times! ($@)"
  fi

  set -e

  return $exitCode
}

# This dirty-as-fuck function is needed to add the magiskinit binary into the ramdisk of the BOOT image (which is, in fact, the recovery's ramdisk on system-as-root device)
add_magisk(){
  #https://stackoverflow.com/questions/3601515/how-to-check-if-a-variable-is-set-in-bash
  if [ -z ${BUILD_NUMBER+x} ]; then
    BUILD_NUMBER=$(cat $BUILD_DIR/out/build_number.txt 2>/dev/null)
  fi

  rm -rf $CHAOSP_DIR/workdir

  mkdir -p $CHAOSP_DIR/workdir

  cd $CHAOSP_DIR/workdir

  # Download latest Magisk release
  curl -s https://api.github.com/repos/topjohnwu/Magisk/releases | grep "Magisk-v.*.zip" |grep https|head -n 1| cut -d : -f 2,3|tr -d \" | wget -O magisk-latest.zip -qi -
  
  # Extract the downloaded zip
  unzip -d magisk-latest magisk-latest.zip 

  # Move the original init binary to the place where Magisk expects it to be
  mkdir -p $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/RAMDISK/.backup
  #cp -n $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/RAMDISK/{system/bin/init,.backup/init}
  ln -f -s /system/bin/init $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/RAMDISK/.backup/init

  # Copy the downloaded magiskinit binary to the place of the original init binary
  rm $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/RAMDISK/init
  cp magisk-latest/arm/magiskinit64 $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/RAMDISK/init

  # Create Magisk config file. We keep dm-verity and encryptiong.
  cat <<EOF > $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/RAMDISK/.backup/.magisk
KEEPFORCEENCRYPT=true
KEEPVERITY=true
RECOVERYMODE=false
EOF

  # Add our "new" files to the list of files to be packaged/compressed/embedded into the final BOOT image
  if ! grep -Fxq ".backup" $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files*/META/boot_filesystem_config.txt
  then
     sed -i "/firmware 0 0 644 selabel=u:object_r:rootfs:s0 capabilities=0x0/a .backup 0 0 000 selabel=u:object_r:rootfs:s0 capabilities=0x0\n.backup/init 0 2000 750 selabel=u:object_r:init_exec:s0 capabilities=0x0\n.backup/.magisk 0 2000 750 selabel=u:object_r:rootfs:s0 capabilities=0x0" $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files*/META/boot_filesystem_config.txt
  fi

  # Retrieve extract-dtb script that will allow us to separate already compiled binary and the concatenated DTB files
  #git clone https://github.com/PabloCastellano/extract-dtb.git

  # Separate kernel and separate DTB files
  #cd extract-dtb
  #python3 ./extract-dtb.py $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/kernel

  # Uncompress the kernel
  #lz4 -d dtb/00_kernel dtb/uncompressed_kernel
  #cd -
	
  echo "Uncompressing the kernel"

  rm -f $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/uncompressed_kernel

  lz4 -d $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/{kernel,uncompressed_kernel}

  # Hexpatch the kernel
  echo "Hex-patching the kernel"
  chmod +x ./magisk-latest/x86/magiskboot
  if grep -Fxq "skip_initramfs" $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/uncompressed_kernel
  then
    ./magisk-latest/x86/magiskboot hexpatch $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/uncompressed_kernel 736B69705F696E697472616D667300 77616E745F696E697472616D667300
  fi

  # Recompress kernel
  echo "Recompressing the kernel"
  lz4 -f -9 $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/{uncompressed_kernel,kernel}
  rm $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/uncompressed_kernel

  # Concatenate back kernel and DTB files
  #rm $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/kernel
  #for file in extract-dtb/dtb/*
  #do
  #  cat $file >> $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER/BOOT/kernel
  #done

  # Remove target files zip
  rm -f $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER.zip

  # Rezip target files
  cd $BUILD_DIR/out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/aosp_$DEVICE-target_files-$BUILD_NUMBER
  zip --symlinks -r ../aosp_$DEVICE-target_files-$BUILD_NUMBER.zip *
  cd -

}

set -e

full_run
