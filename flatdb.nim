#
#
#                     flatdb
#        (c) Copyright 2017 David Krause
#
#    See the file "licence", included in this
#    distribution, for details about the copyright.

import json
import streams
import hashes
import sequtils
import random
import strutils
import flatdbtable
export flatdbtable

when not defined (js):
  import os
  import oids
else:
  import jshelper
  import jsffi
  # from dom import window


randomize() # TODO call this at Main?


## this is the custom build 'database' for nimCh4t 
## this stores msg lines as json but seperated by "\n"
## This is not a _real_ database, so expect a few quirks.

## This database is designed like:
##  - Mostly append only (append only is fast)
##  - Update is inefficent (has to write whole database again)

type 
  Limit = int

  FlatDb* = ref object 
    path*: string
    when not defined (js):
      stream*: FileStream
    # nodes*: OrderedTableRef[string, JsonNode]
    nodes*: FlatDbTable
    inmemory*: bool
    # queryLimit: int # TODO
    manualFlush*: bool ## if this is set to true one has to manually call stream.flush() 
                       ## else it gets called by every db.append()! 
                       ## so set this to true if you want to append a lot of lines in bulk
                       ## set this to false when finished and call db.stream.flush() once.
                       ## TODO should this be db.stream.flush or db.flush??

  EntryId* = string

  Matcher* = proc (x: JsonNode): bool 

  QuerySettings* = ref object
    limit*: int # end query if the result set has this amounth of entries
    skip*: int # skip the first n entries 


# Query Settings ---------------------------------------------------------------------
proc lim*(settings = QuerySettings(), cnt: int): QuerySettings =
  ## limit the smounth of matches
  result = settings
  result.limit = cnt
  # nlimit(10).skip(50)
proc skp*(settings = QuerySettings(), cnt: int): QuerySettings =
  ## skips amounth of matches
  result = settings
  result.skip = cnt

proc newQuerySettings*(): QuerySettings =
  ## Configure the queries, skip, limit found elements ..
  result = QuerySettings()
  result.skip = -1
  result.limit = -1

proc qs*(): QuerySettings =
  ## Shortcut for newQuerySettings
  result = newQuerySettings()
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


proc newFlatDb*(path: string, inmemory: bool = false): FlatDb = 
  # if inmemory is set to true the filesystem gets not touched at all.
  result = FlatDb()
  result.path = path
  result.inmemory = inmemory
  when not defined (js):
    if not inmemory:
      if not fileExists(path):
        open(path, fmWrite).close()    
      result.stream = newFileStream(path, fmReadWriteExisting)
  else:
    # result.inmemory = true
    discard
  result.nodes = newFlatDbTable()
  result.manualFlush = false

proc genId*(): EntryId = 
  ## Mongo id compatible
  return $genOid()

# proc append*(db: FlatDb, node: JObject, eid: EntryId = nil): EntryId {.exportc.} = 
#   # db.append cast[JsonNode](node)

proc append*(db: FlatDb, node: JsonNode, eid: EntryId = nil): EntryId {.exportc.} = 
  ## appends a json node to the opened database file (line by line)
  ## even if the file already exists!
  var id: EntryId
  
  if not eid.isNil or not eid.len == 0:
    id = eid
  elif node.hasKey("_id"):
    id = node["_id"].getStr
  else:
    id = genId()
  
  if not db.inmemory:

    if not node.hasKey("_id"):
      node["_id"] = %* id

    when not defined(js):
      db.stream.writeLine($node)
      if not db.manualFlush:
        db.stream.flush()
    else:
      jsAppend(db.path, ($node))
  
  
  # echo node
  # return
  node.delete("_id") # we dont need the key in memory twice
  db.nodes.add(id, node) 
  return id

proc `[]`*(db: FlatDb, key: string): JsonNode = 
  return db.nodes[key]
  

proc backup*(db: FlatDb) =
  ## Creates a backup of the original db.
  ## We do this to avoid haveing the data only in memory.
  let backupPath = db.path & ".bak"
  when not defined(js):
    removeFile(backupPath) # delete old backup
    copyFile(db.path, backupPath) # copy current db to backup path
  else:
    echo "BACKUP not impletmented on js"
    jsRemove(backupPath) # delete old backup
    jsCopy(db.path, backupPath)






proc drop*(db: FlatDb) = 
  ## DELETES EVERYTHING
  ## deletes the whole database.
  ## after this call we can use the database as normally
  when not defined(js):
    db.stream.close()
    db.stream = newFileStream(db.path, fmWrite)
  else:
    jsRemove(db.path)
    discard jsStore(db.path, "")
  db.nodes.clear()



proc store*(db: FlatDb, nodes: seq[JsonNode]) = 
  ## write every json node to the db.
  ## overwriteing everything.
  ## but creates a backup first
  echo "----------- Store got called on: ", db.path
  db.backup()
  db.drop()
  db.manualFlush = true
  for node in nodes:
    discard db.append(node)
  when not defined(js):
    db.stream.flush()
  else:
    discard jsStore(db.path, $ %* nodes)
  db.manualFlush = false

proc flush*(db: FlatDb) = 
  ## writes the whole memory database to file.
  ## overwrites everything.
  ## If you have done changes in db.nodes you have to call db.flush() to sync it to the filesystem
  # var allNodes = toSeq(db.nodes.values())
  echo "----------- Flush got called on: ", db.path
  var allNodes = newSeq[JsonNode]()
  for id, node in db.nodes.pairs():
    node["_id"] = %* id
    allNodes.add(node)
  db.store(allNodes)

proc load*(db: FlatDb): bool = 
  ## reads the complete flat db and returns true if load sucessfully, false otherwise
  var id: EntryId
  var needForRewrite: bool = false
  when defined (js):
    # echo "LOAD not implemented on js FOR NOW"
    var raw = $jsLoad(db.path)
    var lines = raw.split("\n") 
    for line in lines:
      if line.strip().len == 0: continue
      var j = parseJson(line)
      echo "JJJJ ", j
      # echo j
      if not j.hasKey("_id"):
        id = genId()
        needForRewrite = true     
      else:
        id = j["_id"].getStr()
        j.delete("_id") # we already have the id as table key 
      db.nodes.add(id, j)
    return true
  
  else:
    var line: string  = ""
    var obj: JsonNode
    db.nodes.clear()

    if db.stream.isNil():
      return false

    while db.stream.readLine(line):
      obj = parseJson(line)
      if not obj.hasKey("_id"):
          id = genId()
          needForRewrite = true
      else:
          id = obj["_id"].getStr()
          obj.delete("_id") # we already have the id as table key 
      db.nodes.add(id, obj)
    if needForRewrite:
      echo "Generated missing ids rewriting database"
      db.flush()
    return true

proc len*(db: FlatDb): int = 
  return db.nodes.len()

proc getNode*(db: FlatDb, key: EntryId): Node =
  return db.nodes.getNode($key)

# ----------------------------- Query Iterators -----------------------------------------
template queryIterImpl(direction: untyped, settings: QuerySettings) = 
  var founds: int = 0
  var skipped: int = 0
  for id, entry in direction():
    if matcher(entry):
      if settings.skip != -1 and skipped < settings.skip:
        skipped.inc
        continue
      if founds == settings.limit and settings.limit != -1:
        break
      else:
        founds.inc
      entry["_id"] = % id
      yield entry
      entry.delete("_id") #= % id

iterator queryIter*(db: FlatDb, matcher: Matcher ): JsonNode = 
  let settings = newQuerySettings()
  queryIterImpl(db.nodes.pairs, settings)

iterator queryIterReverse*(db: FlatDb, matcher: Matcher ): JsonNode = 
  let settings = newQuerySettings()
  queryIterImpl(db.nodes.pairsReverse, settings)

iterator queryIter*(db: FlatDb, settings: QuerySettings,  matcher: Matcher ): JsonNode = 
  queryIterImpl(db.nodes.pairs, settings)

iterator queryIterReverse*(db: FlatDb, settings: QuerySettings, matcher: Matcher ): JsonNode = 
  queryIterImpl(db.nodes.pairsReverse, settings)


# ----------------------------- Query -----------------------------------------
template queryImpl*(direction: untyped, settings: QuerySettings)  = 
  return toSeq(direction(settings, matcher))

proc query*(db: FlatDb, matcher: Matcher ): seq[JsonNode] =
  let settings = newQuerySettings()
  queryImpl(db.queryIter, settings)

proc query*(db: FlatDb, settings: QuerySettings, matcher: Matcher ): seq[JsonNode] =
  queryImpl(db.queryIter, settings)


proc queryReverse*(db: FlatDb, matcher: Matcher ): seq[JsonNode] =
  let settings = newQuerySettings()
  queryImpl(db.queryIterReverse, settings)

proc queryReverse*(db: FlatDb, settings: QuerySettings,  matcher: Matcher ): seq[JsonNode] =
  queryImpl(db.queryIterReverse, settings)


# ----------------------------- QueryOne -----------------------------------------
template queryOneImpl(direction: untyped) = 
  for entry in direction(matcher):
    if matcher(entry):
      return entry
  return nil  

proc queryOne*(db: FlatDb, matcher: Matcher ): JsonNode = 
  ## just like query but returns the first match only (iteration stops after first)
  queryOneImpl(db.queryIter)
proc queryOneReverse*(db: FlatDb, matcher: Matcher ): JsonNode = 
  ## just like query but returns the first match only (iteration stops after first)
  queryOneImpl(db.queryIterReverse)


proc queryOne*(db: FlatDb, id: EntryId, matcher: Matcher ): JsonNode = 
  ## returns the entry with `id` and also matching on matcher, if you have the _id, use it, its fast.
  if not db.nodes.hasKey(id):
    return nil
  if matcher(db.nodes[id]):
    return db.nodes[id]
  return nil


proc exists*(db: FlatDb, matcher: Matcher ): bool =
  ## returns true if we found at least one match
  if db.queryOne(matcher).isNil:
    return false
  return true

proc notExists*(db: FlatDb, matcher: Matcher ): bool =
  ## returns false if we found no match
  if db.queryOne(matcher).isNil:
    return true
  return false



# ----------------------------- Matcher -----------------------------------------

proc equal*(key: string, val: string): proc = 
  return proc (x: JsonNode): bool = 
    return x.getOrDefault(key).getStr() == val
proc equal*(key: string, val: int): proc = 
  return proc (x: JsonNode): bool = 
    return x.getOrDefault(key).getNum() == val
proc equal*(key: string, val: float): proc = 
  return proc (x: JsonNode): bool = 
    return x.getOrDefault(key).getFnum() == val
proc equal*(key: string, val: bool): proc = 
  return proc (x: JsonNode): bool = 
    return x.getOrDefault(key).getBool() == val


proc lower*(key: string, val: int): proc = 
  return proc (x: JsonNode): bool = x.getOrDefault(key).getNum < val
proc lower*(key: string, val: float): proc = 
  return proc (x: JsonNode): bool = x.getOrDefault(key).getFnum < val
proc lowerEqual*(key: string, val: int): proc = 
  return proc (x: JsonNode): bool = x.getOrDefault(key).getNum <= val
proc lowerEqual*(key: string, val: float): proc = 
  return proc (x: JsonNode): bool = x.getOrDefault(key).getFnum <= val


proc higher*(key: string, val: int): proc = 
  return proc (x: JsonNode): bool = x.getOrDefault(key).getNum > val
proc higher*(key: string, val: float): proc = 
  return proc (x: JsonNode): bool = x.getOrDefault(key).getFnum > val
proc higherEqual*(key: string, val: int): proc = 
  return proc (x: JsonNode): bool = x.getOrDefault(key).getNum >= val
proc higherEqual*(key: string, val: float): proc = 
  return proc (x: JsonNode): bool = x.getOrDefault(key).getFnum >= val


proc contains*(key: string, val: string): proc = 
  return proc (x: JsonNode): bool = val in x.getOrDefault(key).getStr.contains


proc between*(key: string, fromVal:float, toVal: float): proc =
  return proc (x: JsonNode): bool = 
    let val = x.getOrDefault(key).getFnum
    val > fromVal and val < toVal
proc between*(key: string, fromVal:int, toVal: int): proc =
  return proc (x: JsonNode): bool = 
    let val = x.getOrDefault(key).getNum
    val > fromVal and val < toVal
proc betweenEqual*(key: string, fromVal:float, toVal: float): proc =
  return proc (x: JsonNode): bool = 
    let val = x.getOrDefault(key).getFnum
    val >= fromVal and val <= toVal
proc betweenEqual*(key: string, fromVal:int, toVal: int): proc =
  return proc (x: JsonNode): bool = 
    let val = x.getOrDefault(key).getNum
    val >= fromVal and val <= toVal

proc has*(key: string): proc = 
  return proc (x: JsonNode): bool = return x.hasKey(key)

proc `and`*(p1, p2: proc (x: JsonNode): bool): proc (x: JsonNode): bool =
  return proc (x: JsonNode): bool = return p1(x) and p2(x)

proc `or`*(p1, p2: proc (x: JsonNode): bool): proc (x: JsonNode): bool =
  return proc (x: JsonNode): bool = return p1(x) or p2(x)

proc `not`*(p1: proc (x: JsonNode): bool): proc (x: JsonNode): bool =
  return proc (x: JsonNode): bool = return not p1(x)


proc close*(db: FlatDb) = 
  when not defined(js):
    db.stream.flush()
    db.stream.close()

proc keepIf*(db: FlatDb, matcher: proc) = 
  ## filters the database file, only lines that match `matcher`
  ## will be in the new file.
  # TODO 
  db.store db.query matcher


proc delete*(db: FlatDb, id: EntryId) =
  ## deletes entry by id, respects `manualFlush`
  var hit = false
  if db.nodes.hasKey(id):
      hit = true
      db.nodes.del(id)
  if not db.manualFlush and hit:
    db.flush()

template deleteImpl(direction: untyped) = 
  var hit = false
  for item in direction( matcher ):
    hit = true
    db.nodes.del(item["_id"].getStr)
  if (not db.manualFlush) and hit:
    db.flush()
proc delete*(db: FlatDb, matcher: Matcher ) =
  ## deletes entry by matcher, respects `manualFlush`
  ## TODO make this in the new form (withouth truncate every time)  
  deleteImpl db.queryIter
proc deleteReverse*(db: FlatDb, matcher: Matcher ) =
  ## deletes entry by matcher, respects `manualFlush`
  ## TODO make this in the new form (withouth truncate every time)  
  deleteImpl db.queryIterReverse    

when isMainModule:
  import algorithm
  ## tests
  # block:
    # var db = newFlatDb("test.db", false)
    # db.drop()
    # var orgEntry = %* {"my": "test"}
    # var id = db.append(orgEntry)
    # assert db.nodes[id] == orgEntry
    # assert toSeq(db.nodes.values())[0] == orgEntry
    # db.drop()
    # assert db.nodes.hasKey(id) == false
    # db.close()

  block:
    # fast write test
    let howMany = 10

    var db = newFlatDb("test.db", false)
    db.drop()
    var ids = newSeq[EntryId]()
    for each in 0..howMany:
      # echo "w:", each
      var entry = %* {"foo": each}
      ids.add db.append(entry)
    # echo db.nodes
    db.close()

    # quit()
    # Now read everything again and check if its good
    db = newFlatDb("test.db", false)
    assert true == db.load()
    var cnt = 0
    for id in ids:
      var entry = %* {"foo": cnt}
      # echo entry
      assert db.nodes[id] == entry
      cnt.inc

    # echo "passed"
    # Test if table preserves order
    var idx = 0
    for each in db.nodes.values():
      var entry = %* {"foo": idx}
      assert each == entry
      idx.inc
    db.close()

  block:
    var db = newFlatDb("test.db", false)
    # assert true == db.load()
    db.drop()

    for each in 0..100:
      var entry = %* {"foo": each}
      discard db.append(entry)
    db.close()

    db.keepIf(proc(x: JsonNode): bool = return x["foo"].getNum mod 2 == 0 )
    echo toSeq(db.nodes.values())[0]
    db.keepIf(proc(x: JsonNode): bool = return x["foo"].getNum mod 2 == 0 )
    echo toSeq(db.nodes.values())[0]
    # quit()
    db.close()

  block: #bug outofbound
    var db = newFlatDb("test.db", false)
    discard db.load()
    var entry = %* {"type":"message","to":"lobby","from":"sn0re","content":"asd"}
    discard db.append(entry)
    db.close()

  block: 
      # an example of an "update"
      var db = newFlatDb("test.db", false)
      db.drop()

      # testdata
      var entry: JsonNode
      entry = %* {"user":"sn0re", "password": "asdflkjsaflkjsaf"}
      discard db.append(entry)  

      entry = %* {"user":"klaus", "password": "hahahahsdfksafjj"}
      let id =  db.append(entry)  

      # The actual update
      db.nodes[id]["password"] = % "123"
      # echo db.nodes

      db.flush()
      db.close()


  block :
      var db = newFlatDb("test.db", false)
      db.drop()

      # testdata
      var entry: JsonNode
      entry = %* {"user":"sn0re", "password": "pw1"}
      discard db.append(entry)      

      entry = %* {"user":"sn0re", "password": "pw2"}
      discard db.append(entry)      

      entry = %* {"user":"sn0re", "password": "pw3"}
      discard db.append(entry)      

      entry = %* {"user":"klaus", "password": "asdflkjsaflkjsaf"}
      discard db.append(entry)

      entry = %* {"user":"uggu", "password": "asdflkjsaflkjsaf"}
      discard db.append(entry)

      assert db.query((equal("user", "sn0re") and equal("password", "pw2")))[0]["password"].getStr == "pw2"
      let res = db.query((equal("user", "sn0re") and (equal("password", "pw2") or equal("password", "pw1"))))
      assert res[0]["password"].getStr == "pw1"
      assert res[1]["password"].getStr == "pw2"
      # quit()
      db.close()
  block:
      var db = newFlatDb("test.db", false)
      db.drop()

      # testdata
      var entry: JsonNode

      entry = %* {"user":"sn0re", "timestamp": 10.0}
      discard db.append(entry)  

      entry = %* {"user":"sn0re", "timestamp": 100.0}
      discard db.append(entry)  

      entry = %* {"user":"klaus", "timestamp": 200.0}
      discard db.append(entry)  

      entry = %* {"user":"klaus", "timestamp": 250.0}
      discard db.append(entry)  

      echo db.query higher("timestamp", 150.0)
      echo db.query higher("timestamp", 150.0) and lower("timestamp", 210.0)
      echo db.query equal("user", "sn0re") and  (higher("timestamp", 20.0) and ( lower("timestamp", 210.0) ) )

      var res = db.query(not(equal("user", "sn0re")))
      echo res
      echo res[0] == db[res[0]["_id"].getStr]

      db.close()



  block:
      
      var db = newFlatDb("test.db", false)
      db.drop()

      # testdata
      var entry: JsonNode

      entry = %* {"user":"sn0re", "id": 1}
      discard db.append(entry)  

      entry = %* {"user":"sn0re", "id": 2}
      discard db.append(entry)  

      entry = %* {"user":"sn0re", "id": 3}
      discard db.append(entry)  

      entry = %* {"user":"sn0re", "id": 4}
      discard db.append(entry)    

      
      # echo db.query(10.Limit ,  equal("user", "sn0re"))
      # echo db.query( 2.Limit, equal("user", "sn0re") )
      # var entries = db.query( 2, equal("user", "sn0re") )
      # db.query equal("user", "sn0re") 
      # echo db.queryReverse( qs().limit(2) , equal("user", "sn0re") ) #.reversed()
      # var ss = 
      # echo (newQuerySettings().nlimit(10))
      echo "######"
      echo db.queryReverse( qs().lim(2), equal("user", "sn0re") ).reversed()
      echo "^^^^^^"
      # assert db.query(        2, equal("user", "sn0re") ) == @[%* {"user":"sn0re", "id": 1}, %* {"user":"sn0re", "id": 2}] 
      # assert db.queryReverse( 2, equal("user", "sn0re") ) == @[%* {"user":"sn0re", "id": 4}, %* {"user":"sn0re", "id": 3}]

      db.close()



when isMainModule and defined(doNotRun) and not defined(js):
  var db = newFlatDb("test.db", false)
  assert db.load() == true
  var entry = %* {"some": "json", "things": [1,2,3]}
  var entryId = db.append(entry)
  entryId = db.append(entry)
  echo entryId
  echo db.nodes[entryId]
  # for each in db.nodes.values():
    # echo each

  entry = %* {"some": "json", "things": [1,3]}
  entryId = db.append(entry)

  entry = %* {"hahahahahahhaha": "json", "things": [1,2,3]}
  entryId = db.append(entry)

  proc m1(m:JsonNode): bool = 
    # a custom query example
    # test if things[1] == 2
    if not m.hasKey("things"):
      return false
    if not m["things"].len > 1:
      return false
    if m["things"][1].getNum == 2:
      return true
    return false

  echo db.query(m1)
  # entryId = db.append(entry)
  # entryId = db.append(entry)
  # entryId = db.append(entry)

  db.close()



when isMainModule and not defined(js):
  # clear up directory
  removeFile("test.db")
  removeFile("test.db.bak")

when isMainModule and defined(js):
  var db = newFlatDb("test")
  echo db.append( %* {"foo":"baa"} )
  # for each in db.nodes.items:
  #   echo each