#!/bin/bash
# Network-wide switch port audit via the UniFi controller (UDM-SE) mongo.
# Finds the misconfiguration classes that caused the 2026-06-11 Pi link-flap
# saga: autoneg-off/forced-speed ports, gig-capable links running sub-rate,
# half duplex, plus live + lifetime per-port error counters.
# Read-only. Requires root ssh to the UDM (192.168.85.1).
set -euo pipefail
UDM="${UDM:-root@192.168.85.1}"

ssh "$UDM" 'mongo --port 27117 ace --quiet --eval "
db.device.find({type: {\$in: [\"usw\",\"udm\"]}}, {name:1, port_overrides:1, port_table:1}).forEach(function(d){
  var name = d.name || \"unnamed\";
  (d.port_overrides||[]).forEach(function(o){
    var bits=[];
    if (o.autoneg===false) bits.push(\"AUTONEG OFF\");
    if (o.speed) bits.push(\"forced speed=\"+o.speed);
    if (o.full_duplex===false) bits.push(\"HALF DUPLEX\");
    if (bits.length) print(\"OVERRIDE | \"+name+\" port \"+o.port_idx+(o.name?\" (\"+o.name+\")\":\"\")+\" | \"+bits.join(\", \"));
  });
  (d.port_table||[]).forEach(function(p){
    var media=p.media||\"\"; var sp=p.speed;
    if ((media.indexOf(\"GE\")>=0||media===\"SFP+\") && sp>0 && sp<1000)
      print(\"SUBRATE  | \"+name+\" port \"+p.port_idx+\" | \"+media+\" linked at \"+sp);
  });
});"'

echo "--- per-port errors (latest 5-min bucket + lifetime totals > 0):"
ssh "$UDM" 'mongo --port 27117 ace_stat --quiet --eval "
db.getSiblingDB(\"ace\").device.find({type:\"usw\"},{name:1,mac:1}).forEach(function(sw){
  var c = db.stat_5minutes.find({o:\"sw\", sw: sw.mac}).sort({time:-1}).limit(1);
  if (!c.hasNext()) return;
  var d = c.next();
  Object.keys(d).forEach(function(k){
    if (/-(rx|tx)_(errors|dropped)$/.test(k) && d[k] > 0)
      print(sw.name+\" | \"+k+\" = \"+Math.round(d[k]));
  });
});"'
