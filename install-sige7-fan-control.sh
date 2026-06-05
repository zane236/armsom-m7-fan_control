#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="sige7-fan-control"
SCRIPT_PATH="/usr/local/sbin/${SERVICE_NAME}.sh"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root:"
  echo "sudo bash install-sige7-fan-control.sh"
  exit 1
fi

echo "==> Checking pwmfan device"

FAN_FOUND=0
for d in /sys/class/hwmon/hwmon*; do
  if [ -f "$d/name" ] && [ "$(cat "$d/name")" = "pwmfan" ]; then
    echo "Found pwmfan: $d"
    FAN_FOUND=1
    break
  fi
done

if [ "$FAN_FOUND" -ne 1 ]; then
  echo "Warning: pwmfan was not found."
  echo "If this is an ArmSoM Sige7 / BPI-M7 board, you can continue installing."
  echo "The service will keep retrying after boot."
fi

echo "==> Writing fan control script: $SCRIPT_PATH"

cat > "$SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INTERVAL=5

find_fan() {
  for d in /sys/class/hwmon/hwmon*; do
    if [ -f "$d/name" ] && [ "$(cat "$d/name")" = "pwmfan" ]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

get_max_temp() {
  local max=0
  local t

  for f in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp*_input; do
    [ -f "$f" ] || continue
    t="$(cat "$f" 2>/dev/null || echo 0)"
    [[ "$t" =~ ^[0-9]+$ ]] || continue
    [ "$t" -gt "$max" ] && max="$t"
  done

  echo "$max"
}

pwm_for_temp() {
  local temp_milli="$1"
  local temp=$((temp_milli / 1000))

  if [ "$temp" -lt 45 ]; then
    echo 95
  elif [ "$temp" -lt 55 ]; then
    echo 95
  elif [ "$temp" -lt 65 ]; then
    echo 145
  elif [ "$temp" -lt 75 ]; then
    echo 195
  else
    echo 255
  fi
}

while true; do
  FAN="$(find_fan || true)"

  if [ -z "$FAN" ]; then
    echo "$(date '+%F %T') pwmfan not found, retrying..."
    sleep "$INTERVAL"
    continue
  fi

  PWM="$FAN/pwm1"
  ENABLE="$FAN/pwm1_enable"

  if [ ! -w "$PWM" ] || [ ! -w "$ENABLE" ]; then
    echo "$(date '+%F %T') pwmfan found, but pwm files are not writable: $FAN"
    sleep "$INTERVAL"
    continue
  fi

  echo 2 > "$ENABLE"

  last_pwm=-1

  while [ -e "$PWM" ] && [ -e "$ENABLE" ]; do
    temp="$(get_max_temp)"
    pwm="$(pwm_for_temp "$temp")"

    if [ "$pwm" != "$last_pwm" ]; then
      echo "$pwm" > "$PWM"
      echo "$(date '+%F %T') fan=$FAN temp=$((temp / 1000))C pwm=$pwm"
      last_pwm="$pwm"
    fi

    sleep "$INTERVAL"
  done

  echo "$(date '+%F %T') pwmfan device disappeared, rescanning..."
done
EOF

chmod 755 "$SCRIPT_PATH"

echo "==> Writing systemd service: $SERVICE_PATH"

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=ArmSoM Sige7 PWM Fan Control
After=multi-user.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "==> Reloading systemd"
systemctl daemon-reload

echo "==> Enabling and starting service"
systemctl enable --now "$SERVICE_NAME.service"

echo "==> Current service status"
systemctl --no-pager --full status "$SERVICE_NAME.service" || true

echo
echo "Installation completed."
echo
echo "Common commands:"
echo "Check status: systemctl status $SERVICE_NAME.service"
echo "View logs: journalctl -u $SERVICE_NAME.service -f"
echo "Restart service: sudo systemctl restart $SERVICE_NAME.service"
echo "Stop service: sudo systemctl stop $SERVICE_NAME.service"
echo
echo "Current hwmon devices:"
for d in /sys/class/hwmon/hwmon*; do
  if [ -f "$d/name" ]; then
    echo "$d: $(cat "$d/name")"
    ls "$d"/pwm* 2>/dev/null || true
  fi
done
