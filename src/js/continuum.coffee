if this.Continuum
  Continuum = this.Continuum
else
  Continuum = {}
  this.Continuum = Continuum
Collections = {}
Continuum.Collections = Collections
Continuum.register_collection = (key, value) ->
  Collections[key] = value
  value.bokeh_key = key

safebind = (binder, target, event, callback) ->
  # stores objects we are binding events on, so that if we go away,
  # we can unbind all our events
  # currently, we require that the context being used is the binders context
  # this is because we currently unbind on a per context basis.  this can
  # be changed later if we need it
  if not _.has(binder, 'eventers')
    binder['eventers'] = {}
  binder['eventers'][target.id] = target
  target.on(event, callback, binder)
  # also need to bind destroy to remove obj from eventers.
  # no special logic needed to manage this life cycle, because
  # we will already unbind all listeners on target when binder goes away
  target.on('destroy',
    () =>
      delete binder['eventers'][target]
    ,binder)

## data driven properties
## also has infrastructure for auto removing events bound via safebind
class HasProperties extends Backbone.Model
  collections : Collections
  destroy : ->
    if _.has(this, 'eventers')
      for own target, val of @eventers
        val.off(null, null, this)
    super()

  initialize : (attrs, options) ->
    super(attrs, options)

    @properties = {}
    @property_cache = {}
    if not _.has(attrs, 'id')
      this.id = _.uniqueId(this.type)
      this.attributes['id'] = this.id

  set : (key, value, options) ->
    if _.isObject(key) or key == null
      attrs = key
      options = value
    else
      attrs = {}
      attrs[key] = value
    toremove  = []
    for own key, val of attrs
      if _.has(this, 'properties') and
         _.has(@properties, key) and
         @properties[key]['setter']
        @properties[key]['setter'](this, val)
    for key in toremove
      delete attrs[key]
    if not _.isEmpty(attrs)
      super(attrs, options)

  structure_dependencies : (dependencies) ->
    other_deps = (x for x in dependencies when _.isObject(x))
    local_deps = (x for x in dependencies when not _.isObject(x))
    if local_deps.length > 0
      deps = [{'ref' : this.ref(), 'fields' : local_deps}]
    deps = deps.concat(other_deps)
    return deps

  register_property : \
    (prop_name, dependencies, property, use_cache, setter) ->
      # property, key is prop name, value is list of dependencies
      # dependencies is a list [{'ref' : ref, 'fields' : fields}]
      # if you pass a string in for dependency, we assume that
      # it is a field name on this object
      # if any obj in dependencies is destroyed, we automatically remove the property
      # dependency changes trigger a changedep:propname event
      # in response to that event, we will invalidate the cache if we are caching
      # we will trigger a change:propname event
      # registering properties creates circular references, the other object
      # has a refernece to this because of how callbacks are stored, and we need to
      # store a refrence to that object
      if _.has(@properties, prop_name)
        @remove_property(prop_name)
      dependencies = @structure_dependencies(dependencies)
      prop_spec=
        'property' : property,
        'dependencies' : dependencies,
        'use_cache' : use_cache
        'setter' : setter
        'callbacks':
          'changedep' : =>
            @trigger('changedep:' + prop_name)
          'invalidate_cache' : =>
            @clear_cache(prop_name)
          'eventgen' : =>
            @trigger('change:' + prop_name, this, @get(prop_name))

      @properties[prop_name] = prop_spec
      for dep in dependencies
        obj = @resolve_ref(dep['ref'])
        for fld in dep['fields']
          safebind(this, obj, "change:" + fld, prop_spec['callbacks']['changedep'])
      if prop_spec['use_cache']
        safebind(this, this, "changedep:" + prop_name,
          prop_spec['callbacks']['invalidate_cache'])
      safebind(this, this, "changedep:" + prop_name,
          prop_spec['callbacks']['eventgen'])

  remove_property : (prop_name) ->
    prop_spec = @properties[prop_name]
    dependencies = prop_spec.dependencies
    for dep in dependencies
      obj = @resolve_ref(dep['ref'])
      for fld in dep['fields']
        obj.off('change:' + fld, prop_spec['callbacks']['changedep'], this)
    @off("changedep:" + dep)
    delete @properties[prop_name]
    if prop_spec.use_cache
      @clear_cache(prop_name)

  has_cache : (prop_name) ->
    return _.has(@property_cache, prop_name)

  add_cache : (prop_name, val) ->
    @property_cache[prop_name] = val

  clear_cache : (prop_name, val) ->
    delete @property_cache[prop_name]

  get_cache : (prop_name) ->
    return @property_cache[prop_name]

  get : (prop_name) ->
    if _.has(@properties, prop_name)
      prop_spec = @properties[prop_name]
      if prop_spec.use_cache and @has_cache(prop_name)
        return @property_cache[prop_name]
      else
        property = prop_spec.property
        computed = property.apply(this, this)
        if @properties[prop_name].use_cache
          @add_cache(prop_name, computed)
        return computed
    else
      return super(prop_name)

  ref : ->
    'type' : this.type
    'id' : this.id

  resolve_ref : (ref) ->
    #this way we can reference ourselves
    # even though we are not in any collection yet
    if ref['type'] == this.type and ref['id'] == this.id
      return this
    else
      @collections[ref['type']].get(ref['id'])

  get_ref : (ref_name) ->
    ref = @get(ref_name)
    if ref
      return @resolve_ref(ref)

class ContinuumView extends Backbone.View
  initialize : (options) ->
    if not _.has(options, 'id')
      this.id = _.uniqueId('ContinuumView')
  remove : ->
    if _.has(this, 'eventers')
      for own target, val of @eventers
        val.off(null, null, this)
    super()

  tag_selector : (tag, id) ->
    return "#" + @tag_id(tag, id)

  tag_id : (tag, id) ->
    if not id
      id = this.id
    tag + "-" + id
  tag_el : (tag, id) ->
    @$el.find("#" + this.tag_id(tag, id))
  tag_d3 : (tag, id) ->
    val = d3.select(this.el).select("#" + this.tag_id(tag, id))
    if val[0][0] == null
      return null
    else
      return val
  mget : (fld)->
    return @model.get(fld)
  mget_ref : (fld) ->
    return @model.get_ref(fld)

# hasparent
# display_options can be passed down to children
# defaults for display_options should be placed
# in a class var display_defaults
# the get function, will resolve an instances defaults first
# then check the parents actual val, and finally check class defaults.
# display options cannot go into defaults

class HasParent extends HasProperties
  get_fallback : (attr) ->
    if (@get_ref('parent') and
        _.indexOf(@get_ref('parent').parent_properties, attr) >= 0 and
        not _.isUndefined(@get_ref('parent').get(attr)))
      return @get_ref('parent').get(attr)
    else
      return @display_defaults[attr]
  get : (attr) ->
    ## no fallback for 'parent'
    if not _.isUndefined(super(attr))
      return super(attr)
    else if not (attr == 'parent')
      return @get_fallback(attr)

  display_defaults : {}


class TableView extends ContinuumView
  delegateEvents: ->
    safebind(this, @model, 'destroy', @remove)
    safebind(this, @model, 'change', @render)

  render : ->
    @$el.empty()
    @$el.append("<table></table>")
    @$el.find('table').append("<tr></tr>")
    headerrow = $(@$el.find('table').find('tr')[0])
    for column, idx in ['row'].concat(@mget('columns'))
      elem = $(_.template('<th class="tableelem tableheader">{{ name }}</th>',
        {'name' : column}))
      headerrow.append(elem)
    for row, idx in @mget('data')
      row_elem = $("<tr class='tablerow'></tr>")
      rownum = idx + @mget('data_slice')[0]
      for data in [rownum].concat(row)
        elem = $(_.template("<td class='tableelem'>{{val}}</td>",
          {'val':data}))
        row_elem.append(elem)
      @$el.find('table').append(row_elem)

    @render_pagination()

    if !@$el.is(":visible")
      @$el.dialog(
        close :  () =>
          @remove()
      )

  render_pagination : ->
    if @mget('offset') > 0
      node = $("<button>first</button>").css({'cursor' : 'pointer'})
      @$el.append(node)
      node.click(=>
        @model.load(0)
        return false
      )
      node = $("<button>previous</button>").css({'cursor' : 'pointer'})
      @$el.append(node)
      node.click(=>
        @model.load(_.max([@mget('offset') - @mget('chunksize'), 0]))
        return false
      )

    maxoffset = @mget('total_rows') - @mget('chunksize')
    if @mget('offset') < maxoffset
      node = $("<button>next</button>").css({'cursor' : 'pointer'})
      @$el.append(node)
      node.click(=>
        @model.load(_.min([
          @mget('offset') + @mget('chunksize'),
          maxoffset]))
        return false
      )
      node = $("<button>last</button>").css({'cursor' : 'pointer'})
      @$el.append(node)
      node.click(=>
        @model.load(maxoffset)
        return false
      )


class Table extends HasProperties
  type : 'Table'
  initialize : (attrs, options)->
    super(attrs, options)
    @register_property('offset', ['data_slice'],
      () -> return @get('data_slice')[0],
      false)
    @register_property('chunksize', ['data_slice'],
      () -> return @get('data_slice')[1] - @get('data_slice')[0],
      false)

  defaults :
    url : ""
    columns : []
    data : [[]]
    data_slice : [0, 100]
    total_rows : 0
  default_view : TableView
  load : (offset) ->
    @set('data_slice', [offset, offset + @get('chunksize')], {silent:true})
    $.get(@get('url'),
      {
        'data_slice' : JSON.stringify(@get('data_slice'))
      },
      (data) =>
        @set({'data' : JSON.parse(data)['data']})
    )

class Tables extends Backbone.Collection
  model : Table
  url : "/"

Continuum.register_collection('Table', new Tables())

Continuum.ContinuumView = ContinuumView
Continuum.HasProperties = HasProperties
Continuum.HasParent = HasParent
Continuum.safebind = safebind