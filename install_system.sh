#!/system/bin/sh
##################################
# Magisk Delta System Mode Install Script
# Based on original util_functions.sh and manager.sh
##################################

MAGISK_VER='R65C33E4F-kitsune'
MAGISK_VER_CODE=27001

# Get installation directory
INSTALLDIR="$1"

# Define environment variables (same as util_functions.sh)
BOOTMODE=true
TMPDIR=/dev/tmp
MAGISKSYSTEMDIR="/system/etc/init/magisk"

# Set NVBASE and MAGISKBIN
set_nvbase() {
  NVBASE="$1"
  MAGISKBIN="$1/magisk"
}
set_nvbase "/data/adb"

# Essential utility functions from util_functions.sh
ui_print() {
    echo "$1"
}

abort() {
    ui_print "! $1"
    exit 1
}

print_title() {
  local len line1len line2len bar
  line1len=$(echo -n "$1" | wc -c)
  line2len=$(echo -n "$2" | wc -c)
  len=$line2len
  [ $line1len -gt $line2len ] && len=$line1len
  len=$((len + 2))
  bar=$(printf "%${len}s" | tr ' ' '*')
  ui_print "$bar"
  ui_print " $1 "
  [ "$2" ] && ui_print " $2 "
  ui_print "$bar"
}

grep_get_prop() {
  local result
  result=$(getprop "$1" 2>/dev/null)
  echo "$result"
}

api_level_arch_detect() {
  API=$(grep_get_prop ro.build.version.sdk)
  ABI=$(grep_get_prop ro.product.cpu.abi)
  
  ui_print "- Detected ABI: $ABI"
  
  if [ "$ABI" = "x86" ]; then
    ARCH=x86
    ABI32=x86
    IS64BIT=false
  elif [ "$ABI" = "arm64-v8a" ]; then
    ARCH=arm64
    ABI32=armeabi-v7a
    IS64BIT=true
  elif [ "$ABI" = "x86_64" ]; then
    ARCH=x64
    ABI32=x86
    IS64BIT=true
  else
    ARCH=arm
    ABI=armeabi-v7a
    ABI32=armeabi-v7a
    IS64BIT=false
  fi
  
  ui_print "- Architecture: $ARCH (64-bit: $IS64BIT)"
  ui_print "- ABI32: $ABI32"
}

is_rootfs(){
  if ! $BOOTMODE && [ -d /system_root ] && mountpoint /system_root; then
    return 1
  fi
  local mnt_type="$(head -1 /proc/self/mountinfo | awk '{ printf $9 }')"
  if $BOOTMODE && [ "$mnt_type" = "rootfs" -o "$mnt_type" = "tmpfs" ]; then
    return 0
  fi
  return 1
}

warn_system_ro(){
  ui_print "! System partition is read-only"
  return 1
}

remount_check(){
  local mode="$1"
  local part="$(realpath "$2")"
  local ignore_not_exist="$3"
  local i
  if ! grep -q " $part " /proc/mounts && [ ! -z "$ignore_not_exist" ]; then
    return "$ignore_not_exist"
  fi
  mount -o "$mode,remount" "$part"
  local IFS=$'\t\n ,'
  for i in $(cat /proc/mounts | grep " $part " | awk '{ print $4 }'); do
    test "$i" = "$mode" && return 0
  done
  return 1
}

force_bind_mount(){
  mount -o bind,private "$1" "$2"
  mount -o rw,remount "$2"
  remount_check rw "$2" || warn_system_ro
}

# File preparation - based on original updater-script logic
prepare_magisk_files() {
    ui_print "- Preparing Magisk files..."
    
    local BINDIR="$INSTALLDIR/lib/$ABI"
    if [ ! -d "$BINDIR" ]; then
        abort "! Cannot find $ABI binaries in $INSTALLDIR/lib/$ABI"
    fi
    
    # Rename binary files (same as updater-script line 68)
    cd "$BINDIR"
    for file in lib*.so; do
        if [ -f "$file" ]; then
            local newname="${file:3:${#file}-6}"  # Remove lib prefix and .so suffix  
            ui_print "- Preparing $newname"
            mv "$file" "$newname"
        fi
    done
    
    # Copy 32-bit magisk if available (same as updater-script line 70)  
    if [ -f "$INSTALLDIR/lib/$ABI32/libmagisk32.so" ]; then
        cp -af "$INSTALLDIR/lib/$ABI32/libmagisk32.so" "$BINDIR/magisk32"
        ui_print "- Copied magisk32 from $ABI32"
    else
        ui_print "- Warning: magisk32 not available for $ABI32"
    fi
    
    # Copy stub.apk to lib directory for easy access
    if [ -f "$INSTALLDIR/assets/stub.apk" ]; then
        cp "$INSTALLDIR/assets/stub.apk" "$BINDIR/stub.apk"
        ui_print "- Copied stub.apk"
    else
        ui_print "! Warning: stub.apk not found"
    fi
    
    cd "$INSTALLDIR"
    ui_print "- Files prepared successfully"
    
    # Debug: List prepared files
    ui_print "- Available files in $BINDIR:"
    ls -la "$BINDIR/" 2>/dev/null || ui_print "! Cannot list directory"
    
    # Also check what was accidentally moved to lib root
    ui_print "- Files that might be in lib root:"
    ls -la "$INSTALLDIR/lib/" 2>/dev/null | head -10
}

# Environment setup (based on updater-script and manager.sh)
fix_env() {
    ui_print "- Setting up Magisk environment"
    
    # Clean up and create directories
    rm -rf "$MAGISKBIN" 2>/dev/null
    mkdir -p "$MAGISKBIN" 2>/dev/null
    chmod 700 "$NVBASE"
    
    # Copy files to magisk directory (based on updater-script lines 82-94)
    cp -af "$INSTALLDIR/lib/$ABI"/. "$INSTALLDIR/assets"/. "$MAGISKBIN"
    
    # Remove files only used by the Magisk app (updater-script line 87)
    rm -f "$MAGISKBIN/bootctl" "$MAGISKBIN/main.jar" \
      "$MAGISKBIN/module_installer.sh" "$MAGISKBIN/uninstaller.sh"
    
    chmod -R 755 "$MAGISKBIN"
    chown -R 0:0 "$MAGISKBIN" 2>/dev/null
}

# Install addon.d survival script
install_addond() {
    local addond=/system/addon.d
    [ ! -d "$addond" ] && return 0
    
    ui_print "- Installing addon.d survival script"
    mount -o rw,remount /system 2>/dev/null
    
    rm -rf "$addond/99-magisk.sh" "$addond/magisk" 2>/dev/null
    
    if [ -f "$INSTALLDIR/assets/addon.d.sh" ]; then
        # System mode installation - copy files to /system/etc/init/magisk
        cp -prLf "$MAGISKBIN"/. "$MAGISKSYSTEMDIR" 2>/dev/null
        cp "$INSTALLDIR/assets/addon.d.sh" "$addond/99-magisk.sh"
        chmod 755 "$addond/99-magisk.sh"
        sed -i "s/^SYSTEMINSTALL=.*/SYSTEMINSTALL=true/g" "$addond/99-magisk.sh" 2>/dev/null
        ui_print "- Addon.d survival script installed"
    fi
    
    mount -o ro,remount /system 2>/dev/null
}

random_str(){
    local FROM="$1"
    local TO="$2"
    tr -dc A-Za-z0-9 </dev/urandom | head -c $(($FROM+$(($RANDOM%$(($TO-$FROM+1))))))
}

# magiskrc generation (from manager.sh)
magiskrc(){
    local MAGISKTMP="$1"
    local magisk_name="$2"
    [ -z "$magisk_name" ] && magisk_name=magisk32
    [ "$IS64BIT" = true ] && [ -z "$2" ] && magisk_name=magisk64
    
cat <<EOF
on post-fs-data
    start logd
    exec u:r:su:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:magisk:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:update_engine:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:su:s0 root root -- $MAGISKSYSTEMDIR/$magisk_name --auto-selinux --setup-sbin $MAGISKSYSTEMDIR $MAGISKTMP
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --post-fs-data
on nonencrypted
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --service
on property:vold.decrypt=trigger_restart_framework
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --service
on property:sys.boot_completed=1
    mkdir /data/adb/magisk 755
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --boot-complete
   
on property:init.svc.zygote=restarting
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart
   
on property:init.svc.zygote=stopped
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart
EOF
}

# Backup and restore functions
backup_restore(){
    # if gz is not found and orig file is found, backup to gz
    if [ ! -f "${1}.gz" ] && [ -f "$1" ]; then
        gzip -k "$1" && return 0
    elif [ -f "${1}.gz" ]; then
    # if gz found, restore from gz
        rm -rf "$1" && gzip -kdf "${1}.gz" && return 0
    fi
    return 1
}

restore_from_bak(){
    backup_restore "$1" && rm -rf "${1}.gz"
}

cleanup_system_installation(){
    rm -rf "$MIRRORDIR${MAGISKSYSTEMDIR}"
    rm -rf "$MIRRORDIR${MAGISKSYSTEMDIR}.rc"
    backup_restore "$MIRRORDIR/system/etc/init/bootanim.rc" \
    && rm -rf "$MIRRORDIR/system/etc/init/bootanim.rc.gz"
    if [ -e "$MIRRORDIR${MAGISKSYSTEMDIR}" ] || [ -e "$MIRRORDIR${MAGISKSYSTEMDIR}.rc" ]; then
        return 1
    fi
}

backup_restore(){
    # if gz is not found and orig file is found, backup to gz
    if [ ! -f "${1}.gz" ] && [ -f "$1" ]; then
        gzip -k "$1" && return 0
    elif [ -f "${1}.gz" ]; then
    # if gz found, restore from gz
        rm -rf "$1" && gzip -kdf "${1}.gz" && return 0
    fi
    return 1
}

restore_from_bak(){
    backup_restore "$1" && rm -rf "${1}.gz"
}

cleanup_system_installation(){
    rm -rf "$MIRRORDIR${MAGISKSYSTEMDIR}"
    rm -rf "$MIRRORDIR${MAGISKSYSTEMDIR}.rc"
    backup_restore "$MIRRORDIR/system/etc/init/bootanim.rc" \
    && rm -rf "$MIRRORDIR/system/etc/init/bootanim.rc.gz"
    if [ -e "$MIRRORDIR${MAGISKSYSTEMDIR}" ] || [ -e "$MIRRORDIR${MAGISKSYSTEMDIR}.rc" ]; then
        return 1
    fi
}

magiskrc(){
    local MAGISKTMP="$1"
    local magisk_name="magisk64"
    [ "$ABI" = "x86" ] && magisk_name="magisk32"
    [ "$ABI" = "armeabi-v7a" ] && magisk_name="magisk32"
    
cat <<EOF
on post-fs-data
    start logd
    exec u:r:su:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:magisk:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:update_engine:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:su:s0 root root -- $MAGISKSYSTEMDIR/$magisk_name --auto-selinux --setup-sbin $MAGISKSYSTEMDIR $MAGISKTMP
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --post-fs-data
on nonencrypted
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --service
on property:vold.decrypt=trigger_restart_framework
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --service
on property:sys.boot_completed=1
    mkdir /data/adb/magisk 755
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --boot-complete
   
on property:init.svc.zygote=restarting
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart
   
on property:init.svc.zygote=stopped
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart
EOF
}

##################################
# Main Installation Function - Exact copy from manager.sh
##################################

direct_install_system(){
    print_title "Magisk Delta (System Mode)" "by HuskyDG"
    print_title "Powered by Magisk"
    api_level_arch_detect
    local INSTALLDIR="$1"

    ui_print "- Remount system partition as read-write"
    # Use kernel trick to clean up mirrors automatically when installer completed
    local MIRRORDIR="/proc/$$/attr" ROOTDIR SYSTEMDIR VENDORDIR ODM_DIR

    ROOTDIR="$MIRRORDIR/system_root"
    SYSTEMDIR="$MIRRORDIR/system"
    VENDORDIR="$MIRRORDIR/vendor"
    ODM_DIR="$MIRRORDIR/odm"

    local MAGISKTMP_TO_INSTALL=/sbin

    if $BOOTMODE; then
        umount -l "/proc/$$/attr"
        # setup mirrors to get the original content
        mount -t tmpfs -o 'mode=0755' tmpfs "$MIRRORDIR" || return 1
        if is_rootfs; then
            ROOTDIR=/
            mkdir "$SYSTEMDIR"
            force_bind_mount "/system" "$SYSTEMDIR" || return 1
        else
            mkdir "$ROOTDIR"
            force_bind_mount "/" "$ROOTDIR" || return 1
            if mountpoint -q /system; then
                mkdir "$SYSTEMDIR"
                force_bind_mount "/system" "$SYSTEMDIR" || return 1
            else
                ln -fs ./system_root/system "$SYSTEMDIR"
            fi

            # we are modifying system directly so we need to create /sbin if it does not exist
            if [ ! -d "$ROOTDIR"/sbin ]; then
                rm -rf "$ROOTDIR"/sbin
                mkdir "$ROOTDIR"/sbin
                if [ ! -d "$ROOTDIR"/sbin ]; then
                    ui_print "! Can't create tmpfs path /sbin"
                    return 1;
                fi
            fi

        fi

        # check if /vendor is separated fs
        if mountpoint -q /vendor; then
            mkdir "$VENDORDIR"
            force_bind_mount "/vendor" "$VENDORDIR" || return 1
         else
            ln -fs ./system/vendor "$VENDORDIR"
        fi

        # check if /odm is separated fs
        if mountpoint -q /odm; then
            mkdir "$ODM_DIR"
            force_bind_mount "/odm" "$ODM_DIR" || return 1
         else
            ln -fs ./system_root/odm "$ODM_DIR"
        fi
    else
        local MIRRORDIR="/" ROOTDIR SYSTEMDIR VENDORDIR
        ROOTDIR="$MIRRORDIR/system_root"
        SYSTEMDIR="$MIRRORDIR/system"
        VENDORDIR="$MIRRORDIR/vendor"
        ODM_DIR="$MIRRORDIR/odm"
        ui_print "- Mount system partitions as read-write..."
        remount_check rw "$ROOTDIR" 0 || { warn_system_ro; return 1; }
        remount_check rw "$SYSTEMDIR" 0 || { warn_system_ro; return 1; }
        remount_check rw "$VENDORDIR" 0 || { warn_system_ro; return 1; }
        remount_check rw "$ODM_DIR" 0 || { warn_system_ro; return 1; }

        # we are modifying system directly so we need to create /sbin if it does not exist
        if [ -d "$ROOTDIR" ] && [ ! -d "$ROOTDIR"/sbin ]; then
            rm -rf "$ROOTDIR"/sbin
            mkdir "$ROOTDIR"/sbin
            if [ ! -d "$ROOTDIR"/sbin ]; then
                ui_print "! Can't create tmpfs path /sbin"
                return 1;
            fi
        fi

    fi


    ui_print "- Cleaning up enviroment..."
    {
        local checkfile="$MIRRORDIR/system/.check_$(random_str 10 20)"
        # test write, need atleast 20mb
        dd if=/dev/zero of="$checkfile" bs=1024 count=20000 || \
            { rm -rf "$checkfile"; ui_print "! Insufficient free space or system write protection"; return 1; }
        rm -rf "$checkfile"
    }
    cleanup_system_installation || return 1

    local magisk_applet=magisk32 magisk_name=magisk32
    if [ "$IS64BIT" = true ]; then
        magisk_name=magisk64
        magisk_applet="magisk32 magisk64"
    fi

    ui_print "- Copy files to system partition"
    mkdir -p "$MIRRORDIR$MAGISKSYSTEMDIR" || return 1
    for magisk in $magisk_applet magiskpolicy magiskinit stub.apk; do
        local source_file=""
        
        # First try the expected location: lib/ABI/file
        if [ -f "$INSTALLDIR/lib/$ABI/$magisk" ]; then
            source_file="$INSTALLDIR/lib/$ABI/$magisk"
        # Then try the lib root (where files might have been moved by prepare_magisk_files)  
        elif [ -f "$INSTALLDIR/lib/$magisk" ]; then
            source_file="$INSTALLDIR/lib/$magisk"
        fi
        
        if [ -n "$source_file" ]; then
            ui_print "- Copying $magisk from $(dirname "$source_file")"
            cat "$source_file" >"$MIRRORDIR$MAGISKSYSTEMDIR/$magisk" || { ui_print "! Unable to write $magisk to system"; return 1; }
        else
            ui_print "! Warning: $magisk not found in expected locations"
            # Only fail for essential files
            case "$magisk" in
                "magiskpolicy"|"magiskinit"|"stub.apk")
                    ui_print "! Essential file $magisk missing, aborting"
                    return 1
                    ;;
                *)
                    ui_print "- Optional file $magisk missing, continuing"
                    ;;
            esac
        fi
    done
    echo -e "SYSTEMMODE=true\nRECOVERYMODE=false" >"$MIRRORDIR$MAGISKSYSTEMDIR/config"
    chcon -R u:object_r:system_file:s0 "$MIRRORDIR$MAGISKSYSTEMDIR"
    chmod -R 700 "$MIRRORDIR$MAGISKSYSTEMDIR"

    if [ "$API" -gt 24 ]; then

        # test live patch
        {
            if $BOOTMODE; then
                ui_print "- Check if kernel supports dynamic SELinux Policy patch"
                
                # Find magiskpolicy in the correct location
                local magiskpolicy_path=""
                if [ -f "$INSTALLDIR/lib/$ABI/magiskpolicy" ]; then
                    magiskpolicy_path="$INSTALLDIR/lib/$ABI/magiskpolicy"
                elif [ -f "$INSTALLDIR/lib/magiskpolicy" ]; then
                    magiskpolicy_path="$INSTALLDIR/lib/magiskpolicy"
                fi
                
                if [ -n "$magiskpolicy_path" ] && [ -d /sys/fs/selinux ] && ! "$magiskpolicy_path" --live "permissive su" &>/dev/null; then
                    ui_print "! Kernel does not support dynamic SELinux Policy patch"
                    ui_print "- Continuing anyway (this is often fine for system mode)"
                    # Don't return 1 - continue with installation
                elif [ -z "$magiskpolicy_path" ]; then
                    ui_print "! magiskpolicy not found for testing"
                    ui_print "- Continuing anyway"
                else
                    ui_print "- SELinux dynamic patch appears to work"
                fi
            else
                ui_print "W: It's impossible to check kernel compatible in recovery mode"
                ui_print "W: Please make sure your kernel can dynamic patch SELinux Policy"
            fi
            if ! is_rootfs; then
              {
                ui_print "- Patch sepolicy file"
                local sepol file
                for file in /vendor/etc/selinux/precompiled_sepolicy /odm/etc/selinux/precompiled_sepolicy /system/etc/selinux/precompiled_sepolicy /system_root/sepolicy /system_root/sepolicy_debug /system_root/sepolicy.unlocked; do
                    if [ -f "$MIRRORDIR$file" ]; then
                        sepol="$file"
                        break
                    fi
                done
                if [ -z "$sepol" ]; then
                    ui_print "! Cannot find sepolicy file"
                    return 1
                else
                    ui_print "- Target sepolicy is $sepol"
                    backup_restore "$MIRRORDIR$sepol" || { ui_print "! Backup failed"; return 1; }
                    # copy file to cache
                    cp -af "$MIRRORDIR$sepol" "$INSTALLDIR/sepol.in"
                    
                    # Find magiskinit in the correct location
                    local magiskinit_path=""
                    if [ -f "$INSTALLDIR/lib/$ABI/magiskinit" ]; then
                        magiskinit_path="$INSTALLDIR/lib/$ABI/magiskinit"
                    elif [ -f "$INSTALLDIR/lib/magiskinit" ]; then
                        magiskinit_path="$INSTALLDIR/lib/magiskinit"
                    fi
                    
                    if [ -z "$magiskinit_path" ]; then
                        ui_print "! magiskinit not found, skipping sepolicy patch"
                        restore_from_bak "$MIRRORDIR$sepol"
                        return 1
                    fi
                    
                    if ! "$magiskinit_path" --patch-sepol "$INSTALLDIR/sepol.in" "$INSTALLDIR/sepol.out" || ! cp -af "$INSTALLDIR/sepol.out" "$MIRRORDIR$sepol"; then
                        ui_print "! Unable to patch sepolicy file"
                        restore_from_bak "$MIRRORDIR$sepol"
                        return 1
                    fi
                    ui_print "- Patching sepolicy file success!"
                fi
              }
            fi
        }
        ui_print "- Add init boot script"
        {
            hijackrc="$MIRRORDIR/system/etc/init/magisk.rc" 
            if [ -f "$MIRRORDIR/system/etc/init/bootanim.rc" ]; then
                backup_restore "$MIRRORDIR/system/etc/init/bootanim.rc" && hijackrc="$MIRRORDIR/system/etc/init/bootanim.rc"
            fi
        }
        echo "$(magiskrc "$MAGISKTMP_TO_INSTALL" "$magisk_name")" >>"$hijackrc" || return 1
    fi

    ui_print "[*] Reflash your ROM if your ROM is unable to start"
    ui_print "    and do not use this method to install Magisk" 

    $BOOTMODE && installer_cleanup
    true
    return 0
}

installer_cleanup(){
    if $BOOTMODE; then
        umount -l "/proc/$$/attr"
    fi
    mount -o ro,remount /
}

##################################
# Main Execution based on xdirect_install_system from manager.sh
##################################

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    abort "This script must be run as root"
fi

# Change to installation directory  
cd "$INSTALLDIR" || abort "Unable to access installation directory"

# Detect architecture first (needed for file preparation)
api_level_arch_detect

# Prepare files (rename .so files to proper names)
prepare_magisk_files

# Main installation (based on xdirect_install_system)
direct_install_system "$INSTALLDIR" || { 
    cleanup_system_installation
    installer_cleanup
    abort "! Installation failed"
}

# Set up environment after successful system installation
fix_env "$INSTALLDIR"

# Install addon.d for system update survival
install_addond

ui_print "- Done"
exit 0
