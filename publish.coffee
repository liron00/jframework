# Copyright 2015, Quixey Inc.
# All rights reserved.
#
# Licensed under the Modified BSD License found in the
# LICENSE file in the root directory of this source tree.

J.defineModel 'JDataSession', 'jframework_datasessions',
    _id: $$.str

    fields:
        querySpecStrings:
            type: $$.arr


Fiber = Npm.require 'fibers'
Future = Npm.require 'fibers/future'

J._inMethod = new Meteor.EnvironmentVariable

J.methods = (methods) ->
    wrappedMethods = {}
    for methodName, methodFunc of methods
        do (methodName, methodFunc) ->
            wrappedMethods[methodName] = ->
                args = arguments
                J._inMethod.withValue true, =>
                    methodFunc.apply @, args

    Meteor.methods wrappedMethods

# dataSessionId: J.Dict
#     updateObserversFiber: <Fiber>
#     querySpecSet: {qsString: true}
#     mergedQuerySpecs: [
#         {
#             modelName:
#             selector:
#             fields:
#             sort:
#             skip:
#             limit:
#         }
#     ]
J._dataSessions = {}

# Stores Meteor's publisher functions
# sessionId:
#     userId
#     added
#     changed
#     removed
#     ...etc
dataSessionPublisherContexts = {}

# The set of active cursors and exactly what each has sent to the client
# dataSessionId: modelName: docId: fieldName: querySpecString: value
J._dataSessionFieldsByModelIdQuery = {}



Meteor.methods
    _debugPublish: ->
        J._dataSessionFieldsByModelIdQuery


    _updateDataQueries: (dataSessionId, addedQuerySpecs, deletedQuerySpecs) ->
        log = ->
            newArgs = ["[#{dataSessionId}]"].concat _.toArray arguments
            console.log.apply console, newArgs

        log '_updateDataQueries'
#        if addedQuerySpecs.length
#            log '    added:', J.util.stringify qs for qs in addedQuerySpecs
#        if deletedQuerySpecs.length
#            log '    deleted:', J.util.stringify qs for qs in deletedQuerySpecs

        session = J._dataSessions[dataSessionId]
        if not session?
            console.warn "Data session not found", dataSessionId
            throw new Meteor.Error "Data session not found: #{JSON.stringify dataSessionId}"

        for querySpec in addedQuerySpecs
            unless querySpec.modelName of J.models
                throw new Meteor.Error "Invalid modelName in querySpec:
                    #{J.util.stringify querySpec}"

        # Apply the diff to session.querySpecSet()
        actualAdded = []
        actualDeleted = []
        for querySpec in deletedQuerySpecs
            qsString = J.fetching.stringifyQs querySpec
            if session.querySpecSet().hasKey(qsString)
                actualDeleted.push querySpec
                session.querySpecSet().delete qsString
        for querySpec in addedQuerySpecs
            qsString = J.fetching.stringifyQs querySpec
            unless session.querySpecSet().hasKey(qsString)
                actualAdded.push qsString
                session.querySpecSet().setOrAdd qsString, true

        Tracker.flush()

        session.updateObserversFiber = Fiber.current
        updateObservers.call dataSessionPublisherContexts[dataSessionId], dataSessionId
        session.updateObserversFiber = null

        jDataSession = new $$.JDataSession
            _id: dataSessionId
            querySpecStrings: session.querySpecSet().getKeys()
        jDataSession.save ->

        # log '..._updateDataQueries done'


Meteor.publish '_jdata', (dataSessionId) ->
    check dataSessionId, String

    log = ->
        newArgs = ["[#{dataSessionId}]"].concat _.toArray arguments
        console.log.apply console, newArgs

    log 'publish _jdata'

    session = J._dataSessions[dataSessionId] = J.AutoDict(
        "dataSessions[#{dataSessionId}]"

        querySpecSet: J.Dict() # qsString: true

        mergedQuerySpecs: => getMergedQuerySpecs session.querySpecSet()

        observerByQsString: J.Dict()
    )
    dataSessionPublisherContexts[dataSessionId] = @
    J._dataSessionFieldsByModelIdQuery[dataSessionId] = {}

    existingSessionInstance = $$.JDataSession.fetchOne dataSessionId
    if existingSessionInstance?
        existingQuerySpecs = existingSessionInstance.querySpecStrings().map(
            (querySpecString) => J.fetching.parseQs querySpecString
        ).toArr()
        Meteor.call '_updateDataQueries', dataSessionId, existingQuerySpecs, []

    @onStop =>
        console.log "[#{dataSessionId}] PUBLISHER STOPPED"

        removeSession = ->
            session.stop()
            delete J._dataSessionFieldsByModelIdQuery[dataSessionId]
            delete dataSessionPublisherContexts[dataSessionId]
            delete J._dataSessions[dataSessionId]
            $$.JDataSession.remove dataSessionId

        stopObservers = ->
            session.observerByQsString().forEach (qsString, observer) =>
                observer.stop()

        if not session.updateObserversFiber? or not session.updateObserversFiber.started
            console.log "Resetting everything."
            ###
            Current Fiber was either never set, or is stopped and ready to be reset.
            We can stop observers, delete our session, and attempt to restart the Fiber if it exists.
            ###
            stopObservers()
            if session.updateObserversFiber? and not session.updateObserversFiber.started
                console.warn "Uh oh, we were in the middle of updating observers."
                session.updateObserversFiber?.reset()
            removeSession()
        else if session.updateObserversFiber?.started
            # Current Fiber is still running. Stop the observers, but keep our session.
            console.log "Session is still intact."
            stopObservers()

    @ready()


getMergedQuerySpecs = (querySpecSet) =>
    mergedQuerySpecs = J.List()
    querySpecSet.forEach (rawQsString) ->
        # TODO: Fancier merge stuff
        rawQuerySpec = J.fetching.parseQs rawQsString
        mergedQuerySpecs.push rawQuerySpec
    mergedQuerySpecs


updateObservers = (dataSessionId) ->
    log = ->
        newArgs = ["[#{dataSessionId}]"].concat _.toArray arguments
        console.log.apply console, newArgs
    # log "Update observers"

    session = J._dataSessions[dataSessionId]

    oldQsStrings = session.observerByQsString().getKeys()
    newQsStrings = session.mergedQuerySpecs().map(
        (qs) => J.fetching.stringifyQs qs.toObj()
    ).toArr()
    qsStringsDiff = J.util.diffStrings oldQsStrings, newQsStrings

    # console.log "qsStringsDiff", qsStringsDiff

    fieldsByModelIdQuery = J._dataSessionFieldsByModelIdQuery[dataSessionId]


    getMergedSubfields = (a, b) ->
        return a if b is undefined
        return b if a is undefined

        if J.util.isPlainObject(a) and J.util.isPlainObject(b)
            keySet = {}
            keySet[key] = true for key of a
            keySet[key] = true for key of b
            ret = {}
            for key of keySet
                ret[key] = getMergedSubfields a[key], b[key]
            ret
        else
            # It's possible that a != b (by value) right now because
            # one cursor is triggering an observer for an updated value
            # right before all the other cursors are going to trigger
            # observers for the same updated value. It's fine to just
            # arbitrarily pick (a) and let the merge become eventually
            # consistent.
            a


    getField = (modelName, id, fieldName) ->
        fieldValueByQsString = fieldsByModelIdQuery[modelName][id][fieldName] ? {}
        value = _.values(fieldValueByQsString).reduce getMergedSubfields, undefined
        value

    setField = (modelName, id, fieldName, querySpec, value) ->
        modelClass = J.models[modelName]
        qsString = J.fetching.stringifyQs querySpec

        if fieldName is '_reactives'
            # log "#{J.util.stringify querySpec} sees #{JSON.stringify id}._reactives: #{JSON.stringify value}"

            fieldsByModelIdQuery[modelName][id]._reactives ?= {}
            reactivesObj = _.clone fieldsByModelIdQuery[modelName][id]._reactives[qsString] ? {}
            fieldsByModelIdQuery[modelName][id]._reactives[qsString] = reactivesObj

            inclusionSet = J.fetching._projectionToInclusionSet modelClass, querySpec.fields ? {}

            for reactiveName, reactiveSpec of modelClass.reactiveSpecs
                included = false

                if reactiveSpec.denorm
                    for fieldOrReactiveSpec of inclusionSet
                        if fieldOrReactiveSpec.split('.')[0] is reactiveName
                            included = true
                            break

                if included
                    reactiveValue = value[reactiveName]?.val
                    reactiveTs = value[reactiveName]?.ts
                    reactiveExpire = value[reactiveName]?.expire
                    reactiveDirty = not reactiveExpire? or (reactiveExpire < new Date())

                    needsRecalc = false
                    if reactiveDirty
                        needsRecalc = true
                        for qss, qssReactivesObj of fieldsByModelIdQuery[modelName][id]._reactives
                            continue if reactiveName not of qssReactivesObj
                            qssVal = qssReactivesObj[reactiveName].val
                            qssTs = qssReactivesObj[reactiveName].ts
                            qssExpire = qssReactivesObj[reactiveName].expire
                            qssDirty = not qssExpire? or qssExpire < new Date()

                            if not qssDirty and (not reactiveTs? or qssTs > reactiveTs)
                                # A querySpec still thinks it knows what the reactive
                                # value is, so we might not need to recompute it. Either qsString's
                                # cursor will soon observe qss's same value, or else qss and all
                                # the other cursors will observe undefined and the last one will
                                # recalculate the value of reactiveName.
                                needsRecalc = false

                                # Note that qss might be the same as qsString. This is useful
                                # when we've recalculated multiple reactives in the publisher
                                # but the db's _reactives field is still catching up from multiple
                                # update operations (one per reactive)
                                if qss is qsString
                                    reactiveValue = qssVal
                                    reactiveTs = qssTs

                                break

                    if needsRecalc
                        if reactivesObj[reactiveName] is undefined
                            # We know this value is dirty, but publish it anyway.
                            reactivesObj[reactiveName] =
                                val: reactiveValue
                                ts: reactiveTs
                                expire: reactiveExpire

                        # Else keep publishing the previous value of reactivesObj[reactiveName]
                        # until the recalc task gets popped off the queue asynchronously.

                        console.log "Publisher enqueuing <#{modelName} #{JSON.stringify id}>.#{reactiveName}"
                        J.denorm._enqueueReactiveCalc modelName, id, reactiveName

                    else
                        reactivesObj[reactiveName] =
                            val: reactiveValue
                            ts: reactiveTs
                            expire: reactiveExpire

        else
            fieldsByModelIdQuery[modelName][id][fieldName] ?= {}
            fieldsByModelIdQuery[modelName][id][fieldName][qsString] = value


    qsStringsDiff.added.forEach (qsString) =>
        querySpec = J.fetching.parseQs qsString

        # log "Add observer for: ", querySpec

        modelClass = J.models[querySpec.modelName]

        mongoSelector = J.fetching.selectorToMongoSelector modelClass, querySpec.selector
        mongoOptions = J.fetching._qsToMongoOptions querySpec

        # log 'mongoSelector: ', JSON.stringify mongoSelector
        # log 'mongoOptions.fields: ', JSON.stringify mongoOptions.fields

        cursor = modelClass.collection.find mongoSelector, mongoOptions

        observer = cursor.observeChanges
            added: (id, fields) =>
                # log querySpec, "server says ADDED:", JSON.stringify(id), fields

                fields = _.clone fields
                fields._reactives ?= {}

                if id of (fieldsByModelIdQuery?[querySpec.modelName] ? {})
                    # The set of projections being watched on this doc may have grown.
                    changedFields = {}

                    for fieldName, value of fields
                        oldValue = getField querySpec.modelName, id, fieldName
                        setField querySpec.modelName, id, fieldName, querySpec, value
                        newValue = getField querySpec.modelName, id, fieldName
                        if not EJSON.equals oldValue, newValue
                            changedFields[fieldName] = newValue

                    if not _.isEmpty changedFields
                        # log querySpec, "sending CHANGED:", id, changedFields
                        @changed modelClass.collection._name, id, changedFields

                else
                    fieldsByModelIdQuery[querySpec.modelName] ?= {}
                    fieldsByModelIdQuery[querySpec.modelName][id] ?= {}

                    changedFields = {}

                    for fieldName, value of fields
                        setField querySpec.modelName, id, fieldName, querySpec, value
                        changedFields[fieldName] = getField querySpec.modelName, id, fieldName

                    # log querySpec, "sending ADDED:", id, changedFields
                    @added modelClass.collection._name, id, changedFields

            changed: (id, fields) =>
                # log querySpec, "server says CHANGED:", JSON.stringify(id), fields

                fields = _.clone fields
                fields._reactives ?= {}

                changedFields = {}

                for fieldName, value of fields
                    oldValue = getField querySpec.modelName, id, fieldName
                    setField querySpec.modelName, id, fieldName, querySpec, value
                    newValue = getField querySpec.modelName, id, fieldName
                    if not EJSON.equals oldValue, newValue
                        changedFields[fieldName] = newValue

                if not _.isEmpty changedFields
                    # log querySpec, "sending CHANGED:", JSON.stringify(id), changedFields
                    @changed modelClass.collection._name, id, changedFields

            removed: (id) =>
                # log querySpec, "server says REMOVED:", JSON.stringify(id)

                changedFields = {}

                for fieldName in _.keys fieldsByModelIdQuery[querySpec.modelName][id]
                    oldValue = getField querySpec.modelName, id, fieldName
                    delete fieldsByModelIdQuery[querySpec.modelName][id][fieldName][qsString]
                    newValue = getField querySpec.modelName, id, fieldName
                    if not EJSON.equals oldValue, newValue
                        changedFields[fieldName] = newValue
                    if _.isEmpty fieldsByModelIdQuery[querySpec.modelName][id][fieldName]
                        delete fieldsByModelIdQuery[querySpec.modelName][id][fieldName]

                if _.isEmpty fieldsByModelIdQuery[querySpec.modelName][id]
                    delete fieldsByModelIdQuery[querySpec.modelName][id]
                    # log querySpec, "sending REMOVED:", JSON.stringify(id)
                    @removed modelClass.collection._name, id
                else if not _.isEmpty changedFields
                    # log querySpec, "sending CHANGED:", JSON.stringify(id)
                    @changed modelClass.collection._name, id, changedFields

        session.observerByQsString().setOrAdd qsString, observer

    qsStringsDiff.deleted.forEach (qsString) =>
        querySpec = J.fetching.parseQs qsString

        observer = session.observerByQsString().get qsString
        observer.stop()
        session.observerByQsString().delete qsString

        # Send updates to undo the effect that this cursor had on the client's
        # view of the overall data set.
        modelClass = J.models[querySpec.modelName]
        for docId in _.keys fieldsByModelIdQuery[querySpec.modelName] ? {}
            cursorValues = fieldsByModelIdQuery[querySpec.modelName][docId]

            changedFields = {}
            for fieldName in _.keys cursorValues
                valueByQsString = cursorValues[fieldName]
                oldValue = getField querySpec.modelName, docId, fieldName
                delete valueByQsString[qsString]
                newValue = getField querySpec.modelName, docId, fieldName
                if not EJSON.equals oldValue, newValue
                    changedFields[fieldName] = newValue
                if _.isEmpty valueByQsString
                    delete cursorValues[fieldName]

            if _.isEmpty cursorValues
                delete fieldsByModelIdQuery[querySpec.modelName][docId]
                # log querySpec, "sending REMOVED", docId
                @removed modelClass.collection._name, docId
            else if not _.isEmpty changedFields
                # log querySpec, "passing along CHANGED", docId, changedFields
                @changed modelClass.collection._name, docId, changedFields
