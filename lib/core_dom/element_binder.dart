part of angular.core.dom_internal;

class TemplateElementBinder extends ElementBinder {
  final DirectiveRef template;
  ViewFactory templateViewFactory;

  final bool hasTemplate = true;

  final ElementBinder templateBinder;

  var _directiveCache;
  List<DirectiveRef> get _usableDirectiveRefs {
    if (_directiveCache != null) return _directiveCache;
    return _directiveCache = [template];
  }

  TemplateElementBinder(perf, expando, parser, config,
                        this.template, this.templateBinder,
                        onEvents, bindAttrs, childMode)
      : super(perf, expando, parser, config,
          null, null, onEvents, bindAttrs, childMode);

  String toString() => "[TemplateElementBinder template:$template]";

  _registerViewFactory(node, parentInjector, nodeModule) {
    assert(templateViewFactory != null);
    nodeModule
      ..bindByKey(VIEW_PORT_KEY, inject: const [], toFactory: () =>
          new ViewPort(node, parentInjector.getByKey(ANIMATE_KEY)))
      ..bindByKey(VIEW_FACTORY_KEY, toValue: templateViewFactory)
      ..bindByKey(BOUND_VIEW_FACTORY_KEY, inject: const [Injector], toFactory: (Injector injector) =>
          templateViewFactory.bind(injector));
  }
}

// TODO: This class exists for forwards API compatibility only.
//       Remove it after migration to DI 2.0.
class _DirectiveBinderImpl implements DirectiveBinder {
  final module = new Module();

  _DirectiveBinderImpl();

  bind(key, {Function toFactory: DEFAULT_VALUE, List inject: null,
      Visibility visibility: Directive.LOCAL_VISIBILITY}) {
    module.bind(key, toFactory: toFactory, inject: inject,
        visibility: visibility);
  }
}

/**
 * ElementBinder is created by the Selector and is responsible for instantiating
 * individual directives and binding element properties.
 */
class ElementBinder {
  // DI Services
  final Profiler _perf;
  final Expando _expando;
  final Parser _parser;
  final CompilerConfig _config;

  final Map onEvents;
  final Map bindAttrs;

  // Member fields
  final decorators;

  final BoundComponentData componentData;

  // Can be either COMPILE_CHILDREN or IGNORE_CHILDREN
  final String childMode;

  ElementBinder(this._perf, this._expando, this._parser, this._config,
                this.componentData, this.decorators,
                this.onEvents, this.bindAttrs, this.childMode);

  final bool hasTemplate = false;

  bool get shouldCompileChildren =>
      childMode == Directive.COMPILE_CHILDREN;

  var _directiveCache;
  List<DirectiveRef> get _usableDirectiveRefs {
    if (_directiveCache != null) return _directiveCache;
    if (componentData != null) return _directiveCache = new List.from(decorators)..add(componentData.ref);
    return _directiveCache = decorators;
  }

  bool get hasDirectivesOrEvents =>
      _usableDirectiveRefs.isNotEmpty || onEvents.isNotEmpty;

  void _bindTwoWay(tasks, AST ast, scope, directiveScope,
                   controller, AST dstAST) {
    var taskId = (tasks != null) ? tasks.registerTask() : 0;

    var viewOutbound = false;
    var viewInbound = false;
    scope.watchAST(ast, (inboundValue, _) {
      if (!viewInbound) {
        viewOutbound = true;
        scope.rootScope.runAsync(() => viewOutbound = false);
        var value = dstAST.parsedExp.assign(controller, inboundValue);
        if (tasks != null) tasks.completeTask(taskId);
        return value;
      }
    });
    if (ast.parsedExp.isAssignable) {
      directiveScope.watchAST(dstAST, (outboundValue, _) {
        if (!viewOutbound) {
          viewInbound = true;
          scope.rootScope.runAsync(() => viewInbound = false);
          ast.parsedExp.assign(scope.context, outboundValue);
          if (tasks != null) tasks.completeTask(taskId);
        }
      });
    }
  }

  _bindOneWay(tasks, ast, scope, AST dstAST, controller) {
    var taskId = (tasks != null) ? tasks.registerTask() : 0;

    scope.watchAST(ast, (v, _) {
      dstAST.parsedExp.assign(controller, v);
      if (tasks != null) tasks.completeTask(taskId);
    });
  }

  void _bindCallback(dstPathFn, controller, expression, scope) {
    dstPathFn.assign(controller, _parser(expression).bind(scope.context, ScopeLocals.wrapper));
  }


  void _createAttrMappings(directive, scope, List<MappingParts> mappings, nodeAttrs, tasks) {
    Scope directiveScope; // Only created if there is a two-way binding in the element.
    for(var i = 0; i < mappings.length; i++) {
      MappingParts p = mappings[i];
      var attrName = p.attrName;
      var attrValueAST = p.attrValueAST;
      AST dstAST = p.dstAST;

      if (!dstAST.parsedExp.isAssignable) {
        throw "Expression '${dstAST.expression}' is not assignable in mapping '${p.originalValue}' "
              "for attribute '$attrName'.";
      }

      // Check if there is a bind attribute for this mapping.
      var bindAttr = bindAttrs["bind-${p.attrName}"];
      if (bindAttr != null) {
        if (p.mode == '<=>') {
          if (directiveScope == null) {
            directiveScope = scope.createChild(directive);
          }
          _bindTwoWay(tasks, bindAttr, scope, directiveScope,
              directive, dstAST);
        } else if (p.mode == '&') {
          throw "Callbacks do not support bind- syntax";
        } else {
          _bindOneWay(tasks, bindAttr, scope, dstAST, directive);
        }
        continue;
      }

      switch (p.mode) {
        case '@': // string
          var taskId = (tasks != null) ? tasks.registerTask() : 0;
          nodeAttrs.observe(attrName, (value) {
            dstAST.parsedExp.assign(directive, value);
            if (tasks != null) tasks.completeTask(taskId);
          });
          break;

        case '<=>': // two-way
          if (nodeAttrs[attrName] == null) continue;
          if (directiveScope == null) {
            directiveScope = scope.createChild(directive);
          }
          _bindTwoWay(tasks, attrValueAST, scope, directiveScope,
              directive, dstAST);
          break;

        case '=>': // one-way
          if (nodeAttrs[attrName] == null) continue;
          _bindOneWay(tasks, attrValueAST, scope, dstAST, directive);
          break;

        case '=>!': //  one-way, one-time
          if (nodeAttrs[attrName] == null) continue;

          var watch;
          var lastOneTimeValue;
          watch = scope.watchAST(attrValueAST, (value, _) {
            if ((lastOneTimeValue = dstAST.parsedExp.assign(directive, value)) != null && watch != null) {
                var watchToRemove = watch;
                watch = null;
                scope.rootScope.domWrite(() {
                  if (lastOneTimeValue != null) {
                    watchToRemove.remove();
                  } else {  // It was set to non-null, but stablized to null, wait.
                    watch = watchToRemove;
                  }
                });
            }
          });
          break;

        case '&': // callback
          _bindCallback(dstAST.parsedExp, directive, nodeAttrs[attrName], scope);
          break;
      }
    }
  }

  void _link(nodeInjector, probe, scope, nodeAttrs) {
    _usableDirectiveRefs.forEach((DirectiveRef ref) {
      var directive = nodeInjector.getByKey(ref.typeKey);
      if (probe != null) {
        probe.directives.add(directive);
      }

      if (ref.annotation is Controller) {
        scope.context[(ref.annotation as Controller).publishAs] = directive;
      }

      var tasks = directive is AttachAware ? new _TaskList(() {
        if (scope.isAttached) directive.attach();
      }) : null;

      if (ref.mappings.isNotEmpty) {
        if (nodeAttrs == null) nodeAttrs = new _AnchorAttrs(ref);
        _createAttrMappings(directive, scope, ref.mappings, nodeAttrs, tasks);
      }

      if (directive is AttachAware) {
        var taskId = (tasks != null) ? tasks.registerTask() : 0;
        Watch watch;
        watch = scope.watch('1', // Cheat a bit.
            (_, __) {
          watch.remove();
          if (tasks != null) tasks.completeTask(taskId);
        });
      }

      if (tasks != null) tasks.doneRegistering();

      if (directive is DetachAware) {
        scope.on(ScopeEvent.DESTROY).listen((_) => directive.detach());
      }
    });
  }

  void _createDirectiveFactories(DirectiveRef ref, nodeModule, node, nodesAttrsDirectives, nodeAttrs,
                                 visibility) {
    if (ref.type == TextMustache) {
      nodeModule.bind(TextMustache, inject: const [Scope],
          toFactory: (Scope scope) => new TextMustache(node, ref.valueAST, scope));
    } else if (ref.type == AttrMustache) {
      if (nodesAttrsDirectives.isEmpty) {
        nodeModule.bind(AttrMustache, inject: const[Scope], toFactory: (Scope scope) {
          for (var ref in nodesAttrsDirectives) {
            new AttrMustache(nodeAttrs, ref.value, ref.valueAST, scope);
          }
        });
      }
      nodesAttrsDirectives.add(ref);
    } else if (ref.annotation is Component) {
      assert(ref == componentData.ref);

      nodeModule.bindByKey(ref.typeKey, inject: const [Injector],
          toFactory: componentData.factory.call(node), visibility: visibility);
    } else {
      nodeModule.bindByKey(ref.typeKey, visibility: visibility);
    }
  }

  // Overridden in TemplateElementBinder
  void _registerViewFactory(node, parentInjector, nodeModule) {
    nodeModule..bindByKey(VIEW_PORT_KEY, toValue: null)
              ..bindByKey(VIEW_FACTORY_KEY, toValue: null)
              ..bindByKey(BOUND_VIEW_FACTORY_KEY, toValue: null);
  }


  Injector bind(View view, Injector parentInjector, dom.Node node) {
    Injector nodeInjector;
    Scope scope = parentInjector.getByKey(SCOPE_KEY);
    var nodeAttrs = node is dom.Element ? new NodeAttrs(node) : null;
    ElementProbe probe;

    var directiveRefs = _usableDirectiveRefs;
    if (!hasDirectivesOrEvents) return parentInjector;

    var nodesAttrsDirectives = [];
    var nodeModule = new Module()
        ..bindByKey(NG_ELEMENT_KEY)
        ..bindByKey(VIEW_KEY, toValue: view)
        ..bindByKey(ELEMENT_KEY, toValue: node)
        ..bindByKey(NODE_KEY, toValue: node)
        ..bindByKey(NODE_ATTRS_KEY, toValue: nodeAttrs);

    if (_config.elementProbeEnabled) {
      nodeModule.bindByKey(ELEMENT_PROBE_KEY, inject: const [], toFactory: () => probe);
    }

    directiveRefs.forEach((DirectiveRef ref) {
      Directive annotation = ref.annotation;
      var visibility = ref.annotation.visibility;
      if (ref.annotation is Controller) {
        scope = scope.createChild(new PrototypeMap(scope.context));
        nodeModule.bind(Scope, toValue: scope);
      }

      _createDirectiveFactories(ref, nodeModule, node, nodesAttrsDirectives, nodeAttrs,
          visibility);
      // Choose between old-style Module-based API and new-style DirectiveBinder-base API
      var moduleFn = ref.annotation.module;
      if (moduleFn != null) {
        if (moduleFn is DirectiveBinderFn) {
          var binder = new _DirectiveBinderImpl();
          moduleFn(binder);
          nodeModule.install(binder.module);
        } else {
          nodeModule.install(moduleFn());
        }
      }
    });

    _registerViewFactory(node, parentInjector, nodeModule);

    nodeInjector = parentInjector.createChild([nodeModule]);
    if (_config.elementProbeEnabled) {
      probe = _expando[node] =
          new ElementProbe(parentInjector.getByKey(ELEMENT_PROBE_KEY),
                           node, nodeInjector, scope);
      directiveRefs.forEach((DirectiveRef ref) {
        if (ref.valueAST != null) {
          probe.bindingExpressions.add(ref.valueAST.expression);
        }
      });
      scope.on(ScopeEvent.DESTROY).listen((_) {
        _expando[node] = null;
      });
    }

    _link(nodeInjector, probe, scope, nodeAttrs);

    onEvents.forEach((event, value) {
      view.registerEvent(EventHandler.attrNameToEventName(event));
    });
    return nodeInjector;
  }

  String toString() => "[ElementBinder decorators:$decorators]";
}

/**
 * Private class used for managing controller.attach() calls
 */
class _TaskList {
  Function onDone;
  final List _tasks = [];
  bool isDone = false;
  int firstTask;

  _TaskList(this.onDone) {
    if (onDone == null) isDone = true;
    firstTask = registerTask();
  }

  int registerTask() {
    if (isDone) return null; // Do nothing if there is nothing to do.
    _tasks.add(false);
    return _tasks.length - 1;
  }

  void completeTask(id) {
    if (isDone) return;
    _tasks[id] = true;
    if (_tasks.every((a) => a)) {
      onDone();
      isDone = true;
    }
  }

  void doneRegistering() {
    completeTask(firstTask);
  }
}

// Used for walking the DOM
class ElementBinderTreeRef {
  final int offsetIndex;
  final ElementBinderTree subtree;

  ElementBinderTreeRef(this.offsetIndex, this.subtree);
}

class ElementBinderTree {
  final ElementBinder binder;
  final List<ElementBinderTreeRef> subtrees;

  ElementBinderTree(this.binder, this.subtrees);
}

class TaggedTextBinder {
  final ElementBinder binder;
  final int offsetIndex;

  TaggedTextBinder(this.binder, this.offsetIndex);
  String toString() => "[TaggedTextBinder binder:$binder offset:$offsetIndex]";
}

// Used for the tagging compiler
class TaggedElementBinder {
  final ElementBinder binder;
  int parentBinderOffset;
  bool isTopLevel;

  List<TaggedTextBinder> textBinders;

  TaggedElementBinder(this.binder, this.parentBinderOffset, this.isTopLevel);

  void addText(TaggedTextBinder tagged) {
    if (textBinders == null) textBinders = [];
    textBinders.add(tagged);
  }

  bool get isDummy => binder == null && textBinders == null && !isTopLevel;

  String toString() => "[TaggedElementBinder binder:$binder parentBinderOffset:"
                       "$parentBinderOffset textBinders:$textBinders]";
}
