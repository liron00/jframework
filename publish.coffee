###
    Copyright 2015, Quixey Inc.
    All rights reserved.

    Licensed under the Modified BSD License found in the
    LICENSE file in the root directory of this source tree.
###

J.defineModel 'JDataSession', 'jframework_datasessions',
    _id: $$.str

    fields:
        querySpecStrings:
            type: $$.arr


Fiber = Npm.require 'fibers'

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


###
    dataSessionId: J.Dict
        updateObserversFiber: <Fiber>
        querySpecSet: {qsString: true}
        mergedQuerySpecs: [
            {
                modelName:
                selector:
                fields:
                sort:
                skip:
                limit:
            }
        ]
###
dataSessions = {}

###
    Stores Meteor's publisher functions
    sessionId:
        userId
        added
        changed
        removed
        ...etc
###
dataSessionPublisherContexts = {}

###
    The set of active cursors and exactly what each has sent to the client
    dataSessionId: modelName: docId: fieldName: querySpecString: value
###
dataSessionFieldsByModelIdQuery = {}


Meteor.methods
    _updateDataQueries: (dataSessionId, addedQuerySpecs, deletedQuerySpecs) ->
        log = ->
            newArgs = ["[#{dataSessionId}]"].concat _.toArray arguments
            console.log.apply console, newArgs

        log '_updateDataQueries'
#        if addedQuerySpecs.length
#            log '    added:', J.util.stringify qs for qs in addedQuerySpecs
#        if deletedQuerySpecs.length
#            log '    deleted:', J.util.stringify qs for qs in deletedQuerySpecs

        session = dataSessions[dataSessionId]
        if not session?
            console.warn "Data session not found", dataSessionId
            throw new Meteor.Error "Data session not found: #{JSON.stringify dataSessionId}"

        for querySpec in addedQuerySpecs
            unless querySpec.modelName of J.models
                throw new Meteor.Error "Invalid modelName in querySpec:
                    #{J.util.toString querySpec}"

        # Apply the diff to session.querySpecSet()
        actualAdded = []
        actualDeleted = []
        for querySpec in deletedQuerySpecs
            qsString = EJSON.stringify querySpec
            if session.querySpecSet().hasKey(qsString)
                actualDeleted.push querySpec
                session.querySpecSet().delete qsString
        for querySpec in addedQuerySpecs
            qsString = EJSON.stringify querySpec
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
        jDataSession.save()

        # log '..._updateDataQueries done'


Meteor.publish '_jdata', (dataSessionId) ->
    check dataSessionId, String

    log = ->
        newArgs = ["[#{dataSessionId}]"].concat _.toArray arguments
        console.log.apply console, newArgs

    log 'publish _jdata'

    session = dataSessions[dataSessionId] = J.AutoDict(
        "dataSessions[#{dataSessionId}]"

        querySpecSet: J.Dict() # qsString: true

        mergedQuerySpecs: => getMergedQuerySpecs session.querySpecSet()

        observerByQsString: J.Dict()
    )
    dataSessionPublisherContexts[dataSessionId] = @
    dataSessionFieldsByModelIdQuery[dataSessionId] = {}

    existingSessionInstance = $$.JDataSession.fetchOne dataSessionId
    if existingSessionInstance?
        existingQuerySpecs = existingSessionInstance.querySpecStrings().map(
            (querySpecString) => EJSON.parse querySpecString
        ).toArr()
        Meteor.call '_updateDataQueries', dataSessionId, existingQuerySpecs, []

    @onStop =>
        console.log "[#{dataSessionId}] PUBLISHER STOPPED"
        session.stop()

        if session.updateObserversFiber?
            console.warn "Uh oh, we were in the middle of updating observers."
            session.updateObserversFiber.reset()

        delete dataSessionFieldsByModelIdQuery[dataSessionId]
        delete dataSessionPublisherContexts[dataSessionId]
        delete dataSessions[dataSessionId]
        $$.JDataSession.remove dataSessionId

    @ready()


getMergedQuerySpecs = (querySpecSet) =>
    mergedQuerySpecs = J.List()
    querySpecSet.forEach (rawQsString) ->
        # TODO: Fancier merge stuff
        rawQuerySpec = EJSON.parse rawQsString
        mergedQuerySpecs.push rawQuerySpec
    mergedQuerySpecs


updateObservers = (dataSessionId) ->
    log = ->
        newArgs = ["[#{dataSessionId}]"].concat _.toArray arguments
        console.log.apply console, newArgs
    # log "Update observers"

    session = dataSessions[dataSessionId]

    oldQsStrings = session.observerByQsString().getKeys()
    newQsStrings = session.mergedQuerySpecs().map(
        (qs) => EJSON.stringify qs.toObj()
    ).toArr()
    qsStringsDiff = J.util.diffStrings oldQsStrings, newQsStrings

    # console.log "qsStringsDiff", qsStringsDiff

    fieldsByModelIdQuery = dataSessionFieldsByModelIdQuery[dataSessionId]

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
            ###
                It's possible that a != b (by value) right now because
                one cursor is triggering an observer for an updated value
                right before all the other cursors are going to trigger
                observers for the same updated value. It's fine to just
                arbitrarily pick (a) and let the merge become eventually
                consistent.
            ###
            a

    getField = (modelName, id, fieldName) ->
        fieldValueByQsString = fieldsByModelIdQuery[modelName][id][fieldName] ? {}
        _.values(fieldValueByQsString).reduce getMergedSubfields, undefined

    qsStringsDiff.added.forEach (qsString) =>
        querySpec = EJSON.parse qsString

        # log "Add observer for: ", querySpec

        modelClass = J.models[querySpec.modelName]

        options = {}
        for optionName in ['fields', 'sort', 'skip', 'limit']
            if querySpec[optionName]?
                options[optionName] = querySpec[optionName]

        # TODO: Interpret options.fields with fancy semantics

        cursor = modelClass.collection.find querySpec.selector, options

        observer = cursor.observeChanges
            added: (id, fields) =>
                # log querySpec, "server says ADDED:", id, fields

                if id of (fieldsByModelIdQuery?[querySpec.modelName] ? {})
                    # The set of projections being watched on this doc may have grown.
                    changedFields = {}

                    for fieldName, value of fields
                        oldValue = getField querySpec.modelName, id, fieldName
                        fieldsByModelIdQuery[querySpec.modelName][id][fieldName] ?= {}
                        fieldsByModelIdQuery[querySpec.modelName][id][fieldName][qsString] = value
                        newValue = getField querySpec.modelName, id, fieldName
                        if not EJSON.equals oldValue, newValue
                            changedFields[fieldName] = newValue

                    if not _.isEmpty changedFields
                        # log querySpec, "sending CHANGED:", id, changedFields
                        @changed modelClass.collection._name, id, changedFields

                else
                    # log querySpec, "sending ADDED:", id, fields
                    @added modelClass.collection._name, id, fields

                fieldsByModelIdQuery[querySpec.modelName] ?= {}
                fieldsByModelIdQuery[querySpec.modelName][id] ?= {}
                for fieldName, value of fields
                    fieldsByModelIdQuery[querySpec.modelName][id][fieldName] ?= {}
                    fieldsByModelIdQuery[querySpec.modelName][id][fieldName][qsString] = value

            changed: (id, fields) =>
                # log querySpec, "server says CHANGED:", id, fields

                changedFields = {}

                for fieldName, value of fields
                    oldValue = getField querySpec.modelName, id, fieldName
                    fieldsByModelIdQuery[querySpec.modelName][id][fieldName] ?= {}
                    fieldsByModelIdQuery[querySpec.modelName][id][fieldName][qsString] = value
                    newValue = getField querySpec.modelName, id, fieldName
                    if not EJSON.equals oldValue, newValue
                        changedFields[fieldName] = newValue

                if not _.isEmpty changedFields
                    # log querySpec, "sending CHANGED:", id, changedFields
                    @changed modelClass.collection._name, id, changedFields

            removed: (id) =>
                # log querySpec, "server says REMOVED:", id

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
                    # log querySpec, "sending REMOVED:", id
                    @removed modelClass.collection._name, id
                else if not _.isEmpty changedFields
                    # log querySpec, "sending CHANGED:", id
                    @changed modelClass.collection._name, id, changedFields

        session.observerByQsString().setOrAdd qsString, observer

    qsStringsDiff.deleted.forEach (qsString) =>
        querySpec = EJSON.parse qsString

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
