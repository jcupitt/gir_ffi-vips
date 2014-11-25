ruby-vips8
==========

Ruby binding for the vips8 API

Not much here yet, but this where it should happen. If you want something that
works, you need [ruby-vips](https://github.com/jcupitt/ruby-vips).

# What's wrong with ruby-vips?

There's an existing Ruby binding for vips
[here](https://github.com/jcupitt/ruby-vips). It was written by a Ruby
expert, it works well, it includes a test-suite, and has pretty full
documentation. Why do another?

ruby-vips is based on the old vips7 API. There's now vips8, which adds several
very useful new features:

* [GObject](https://developer.gnome.org/gobject/stable/)-based API with full
  introspection. You can discover the vips8 API at runtime. This means that if
  libvips gets a new operator, any binding that goes via vips8 will be able to
  see the new thing immediately. With vips7, whenever libvips was changed, all
  the bindings needed to be changed too.

* No C required. Thanks to
  [gobject-introspection](https://wiki.gnome.org/Projects/GObjectIntrospection)
  you can write the binding in Ruby itself, there's no need for any C. This
  makes it a lot smaller and more portable. 

* vips7 probably won't get new features. vips7 doesn't really exist any more:
  the API is still there, but now just a thin compatibility layer over vips8.
  New features may well not get added to the vips7 API.

There are some more minor pluses as well:

* Named and optional arguments. vips8 lets you have optional and required
  arguments, both input and output, and optional arguments can have default
  values. 

* Operation cache. vips8 keeps track of the last 1,000 or so operations and
  will automatically reuse results when it can. This can give a huge speedup
  in some cases.

* vips8 is much simpler and more regular. For example, 
  ruby-vips had to work hard to offer a nice loader system, but that's all
  built into vips8. It can do things like load and save formatted images to 
  and from memory buffers as well, which just wasn't possible before. 

# Plan

There's a full [vips8 Python
binding](https://github.com/jcupitt/libvips/tree/master/python). The idea is
just to redo that in Ruby. I expect it'll parallel the Python one rather
closely. 

At the moment we're just exploring different gobject-introspection kits for
Ruby and seeing how the API works out. 
