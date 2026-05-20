# Daka

macOS menu bar tracker for recording the first and last time a configurable rule matches each day.

## Run

```bash
swift run daka
```

The app stores data in SQLite on first launch:

```text
~/Library/Application Support/Daka/daka.sqlite
```

Older `config.json` and `records.json` files are imported into SQLite automatically.

## Behavior

Daka does not calculate active-only time. It records:

```text
firstMatchedAt = today's first time the rule matched
lastMatchedAt  = today's latest time the rule matched
duration       = lastMatchedAt - firstMatchedAt
```

If the rule is unmatched in the middle of the day, that gap is not subtracted.

When the rule matches for the first time each day, Daka asks you to confirm that you have clocked in. The first time is written only after you click `已打卡`. Choosing `稍后提醒` delays the next reminder.

Daka compares today's duration with a configurable daily target. The default target is `10.5` hours.

Configuration and statistics are edited through the menu bar UI. SQLite is the storage layer, not the user-facing interface.

## UI

Menu bar actions:

```text
配置...   Open the rule editor
统计...   Open daily records
退出      Quit the menu bar app
```

The config UI supports:

```text
Rule name
Match mode: all / any
Evaluation interval
Daily target hours
Add/remove conditions
Condition parameters
Wi-Fi SSID selection from nearby/current networks
```

The menu shows today's progress with a progress bar and a colored status marker:

```text
red     under 40%
orange  40% - 74%
blue    75% - 99%
green   complete
```

## Storage

Config is stored in `app_config`; daily records are stored in `daily_records`. The default config is:

```json
{
  "evaluationIntervalSeconds": 60,
  "targetDurationSeconds": 37800,
  "rule": {
    "name": "Default",
    "matchMode": "all",
    "conditions": [
      {
        "type": "screenUnlocked"
      }
    ]
  }
}
```

Supported condition types:

```json
{ "type": "screenUnlocked" }
{ "type": "wifiConnected", "ssid": "Company WiFi" }
{ "type": "powerConnected" }
{ "type": "networkReachable", "host": "intranet.company.local", "port": 443 }
{ "type": "timeRange", "start": "08:00", "end": "20:00" }
```

Example:

```json
{
  "evaluationIntervalSeconds": 60,
  "rule": {
    "name": "Office",
    "matchMode": "all",
    "conditions": [
      {
        "type": "screenUnlocked"
      },
      {
        "type": "wifiConnected",
        "ssid": "Company WiFi"
      },
      {
        "type": "powerConnected"
      }
    ]
  }
}
```

Use `配置...` from the menu bar to edit and save the rule.

## Test

```bash
swift test
```
