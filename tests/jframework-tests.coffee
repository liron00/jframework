Tinytest.add "J.dict basics", (test) ->
    d = J.Dict()
    d.setOrAdd x: 5
    test.equal d.get('x'), 5
    test.equal d.size(), 1
    test.throws -> d.set 'newkey': 8
    d.setOrAdd y: 7
    test.equal d.toObj(),
        x: 5
        y: 7
    d.clear()
    test.equal d.toObj(), {}
    test.equal d.size(), 0


Tinytest.add "List basics", (test) ->
    lst = J.List [6, 4]
    test.isTrue lst.contains 4
    test.isFalse lst.contains "4"
    test.equal lst.get(0), 6
    test.throws -> lst.get '0'
    test.throws -> lst.get 2
    test.throws -> lst.get 1.5
    test.equal lst.join('*'), "6*4"
    test.equal lst.map((x) -> 2 * x).toArr(), [12, 8]
    test.equal lst.toArr(), [6, 4]
    lst.push 5
    test.equal lst.toArr(), [6, 4, 5]
    test.equal lst.getSorted().toArr(), [4, 5, 6]
    test.equal lst.toArr(), [6, 4, 5]
    lst.sort()
    test.equal lst.toArr(), [4, 5, 6]
    test.isTrue lst.deepEquals J.List [4, 5, 6]

    lst = J.List([5, 3, [1], 4])
    test.notEqual lst.get(2), [1]
    test.isTrue lst.get(2).deepEquals J.List [1]



Tinytest.add "Dict and list reactivity 1", (test) ->
    lst = J.List [0, 1, 2, 3, 4]
    testOutputs = []
    c = Tracker.autorun (c) ->
        testOutputs.push lst.get(3)
    test.equal testOutputs, [3]
    lst.set 3, 103
    lst.set 3, 203
    test.equal testOutputs, [3]
    Tracker.flush()
    test.equal testOutputs, [3, 203]
    c.stop()

Tinytest.add "Dict and list reactivity 2", (test) ->
    lst = J.List [0, 1, 2, 3, 4]
    nonreactiveMappedLst = lst.map (x) -> 2 * x
    test.equal nonreactiveMappedLst.toArr(), [0, 2, 4, 6, 8]

    reactiveMappedLst = null
    c = Tracker.autorun (c) ->
        reactiveMappedLst = lst.map (x) -> 2 * x
    test.equal reactiveMappedLst.toArr(), [0, 2, 4, 6, 8]

    lst.set 2, 102
    test.equal nonreactiveMappedLst.toArr(), [0, 2, 4, 6, 8]
    test.equal reactiveMappedLst.toArr(), [0, 2, 4, 6, 8]
    Tracker.flush()
    test.equal reactiveMappedLst.toArr(), [0, 2, 204, 6, 8]

    c.stop()

Tinytest.add "Dict and list reactivity 3", (test) ->
    lst = J.List [0, 1, 2, 3, 4]
    c = Tracker.autorun ->
        lst.reverse()
    test.equal lst.toArr(), [4, 3, 2, 1, 0], "Didn't reverse"
    Tracker.flush()
    test.equal lst.toArr(), [4, 3, 2, 1, 0], "Screwed up the reverse"
    c.stop()

Tinytest.add "Dict and list reactivity 4", (test) ->
    lst = J.List [4, 3, 2, 1, 0]
    sortedLst = []
    c = Tracker.autorun ->
        sortedLst = lst.getSorted()
    test.equal lst.toArr(), [4, 3, 2, 1, 0]
    test.equal sortedLst.toArr(), [0, 1, 2, 3, 4]
    lst.set 1, 5
    test.equal lst.toArr(), [4, 5, 2, 1, 0]
    test.equal sortedLst.toArr(), [0, 1, 2, 3, 4]
    Tracker.flush()
    test.equal sortedLst.toArr(), [0, 1, 2, 4, 5]

    c.stop()

Tinytest.add "List resize", (test) ->
    lst = J.List [0, 1, 2, 3, 4]
    size = lst.size()
    test.equal size, 5
    c = Tracker.autorun ->
        size = lst.size()
    lst.resize 10
    test.equal size, 5
    Tracker.flush()
    test.equal size, 10
    test.equal lst.get(9), undefined
    test.throws -> lst.get(10)
    c.stop()

Tinytest.add "Autovar 1", (test) ->
    x = new ReactiveVar 5
    xPlusOne = J.AutoVar -> x.get() + 1
    test.equal xPlusOne.get(), 6
    x.set 10
    test.equal xPlusOne.get(), 11
    Tracker.flush()
    test.equal xPlusOne.get(), 11

Tinytest.add "Autovar - be lazy when no one is looking", (test) ->
    return
    x = new ReactiveVar 5
    runCount = 0
    xPlusOne = J.AutoVar ->
        runCount += 1
        x.get() + 1
    test.equal runCount, 0
    x.set 10
    test.equal runCount, 0
    Tracker.flush()
    test.equal runCount, 0
    test.equal xPlusOne.get(), 11
    test.equal runCount, 1, "fail 1"
    test.equal xPlusOne.get(), 11
    test.equal runCount, 1, "fail 2"
    test.isFalse xPlusOne._var.dep.hasDependents(), "Why do you have dependents? (1)"
    x.set 20
    test.equal runCount, 1, "fail 3"
    Tracker.flush()
    x.set 30
    test.equal runCount, 1, "fail 4"
    Tracker.flush()
    x.set 40
    test.equal runCount, 1, "fail 5"
    Tracker.flush()
    test.equal runCount, 1, "fail 6"
    test.equal xPlusOne.get(), 41
    test.equal runCount, 2
    test.equal xPlusOne.get(), 41
    test.equal runCount, 2
    test.isFalse xPlusOne._var.dep.hasDependents(), "Why do you have dependents? (2)"


Tinytest.add "Autovar - don't be lazy if someone is looking", (test) ->
    x = new ReactiveVar 5
    runCount = 0
    xPlusOne = J.AutoVar ->
        runCount += 1
        x.get() + 1
    test.equal runCount, 0
    watchOnce = Tracker.autorun (watchOnce) ->
        if watchOnce.firstRun
            xPlusOne.get()
    test.equal runCount, 1
    watchMany = Tracker.autorun (watchMany) ->
        xPlusOne.get()
    # runCount is still 1 because xPlusOne's computation
    # is still valid
    test.equal runCount, 1
    Tracker.flush()
    test.equal runCount, 1
    x.set 10
    test.equal runCount, 1
    Tracker.flush()
    test.equal runCount, 2
    Tracker.flush()
    test.equal runCount, 2
    x.set 20
    test.isTrue xPlusOne._var.dep.hasDependents(), "Why don't you have dependents?"
    test.equal runCount, 2
    Tracker.flush()
    test.equal runCount, 3
    watchMany.stop()
    x.set 30
    test.isTrue xPlusOne._valueComp.stopped, "Why didn't you stop valueComp?"
    test.isFalse xPlusOne._var.dep.hasDependents(), "Why do you have dependents? (1)"
    Tracker.flush()
    test.isFalse xPlusOne._var.dep.hasDependents(), "Why do you have dependents? (2)"
    test.equal runCount, 3, "Why are you doing work when no one is looking?"
    watchOnce.stop()


Tinytest.add "Autodict basics", (test) ->
    size = new ReactiveVar 3
    d = J.AutoDict(
        -> ['zero', 'one', 'two', 'three', 'four', 'five'][0...size.get()]
        (key) -> "#{key} is a number"
    )
    test.equal d.getKeys(), ['zero', 'one', 'two']
    test.equal d.toObj(), {'zero': "zero is a number", 'one': "one is a number", 'two': "two is a number"}
    test.equal d.size(), 3
    test.equal d.get('two'), "two is a number"
    test.isUndefined d.get('four')
    size.set 4
    test.equal d.size(), 3
    Tracker.flush()
    test.equal d.size(), 4
    test.equal d.getKeys(), ['zero', 'one', 'two', 'three']
    test.equal d.get('three'), "three is a number"


Tinytest.add "Autodict reactivity", (test) ->
    coef = new ReactiveVar 2
    size = new ReactiveVar 3
    d = J.AutoDict(
        -> ['3', '5', '9', '7'][0...size.get()]
        (key) -> if key is '7' then 'xxx' else coef.get() * parseInt(key)
    )
    dHistory = []
    watcher = Tracker.autorun =>
        dHistory.push d.getFields()
    test.equal dHistory.pop(), {
        3: 6
        5: 10
        9: 18
    }
    coef.set 10
    Tracker.flush()
    test.equal dHistory.pop(), {
        3: 30
        5: 50
        9: 90
    }
    size.set 4
    Tracker.flush()
    test.equal dHistory.pop(), {
        3: 30
        5: 50
        9: 90
        7: 'xxx'
    }
    watcher.stop()

    watcher = Tracker.autorun =>
        dHistory.push d.get('7')
    test.equal dHistory.pop(), 'xxx'
    coef.set 4
    Tracker.flush()
    test.equal dHistory.length, 0
    d.replaceKeysFunc -> ['7', '8']
    Tracker.flush()
    test.equal dHistory.length, 0
    watcher.stop()

    watcher = Tracker.autorun =>
        dHistory.push d.toObj()
    test.equal dHistory.pop(), {
        7: 'xxx'
        8: 32
    }
    d.replaceKeysFunc -> ['8', '9']
    Tracker.flush()
    test.equal dHistory.pop(), {
        8: 32
        9: 36
    }
    watcher.stop()


Tinytest.add "Autodict laziness", (test) ->
    coef = new ReactiveVar 2
    size = new ReactiveVar 3
    keyFuncRunCount = 0
    valueFuncRunCount = 0
    d = J.AutoDict(
        ->
            keyFuncRunCount += 1
            ['3', '5', '9', '7'][0...size.get()]
        (key) ->
            valueFuncRunCount += 1
            if key is '7' then 'xxx' else coef.get() * parseInt(key)
    )
    test.equal keyFuncRunCount, 1
    test.equal valueFuncRunCount, 0
    test.equal d.get('3'), 6
    test.equal valueFuncRunCount, 1
    test.equal d.get('3'), 6
    Tracker.flush()
    test.equal valueFuncRunCount, 1
    test.equal d.get('9'), 18
    Tracker.flush()
    test.equal keyFuncRunCount, 1
    test.equal valueFuncRunCount, 2
























