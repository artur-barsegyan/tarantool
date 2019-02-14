test_run = require('test_run').new()
fiber = require('fiber')
errinj = box.error.injection

--
-- Check that ALTER is abroted if a tuple inserted during space
-- format change does not conform to the new format.
--
format = {}
format[1] = {name = 'field1', type = 'unsigned'}
format[2] = {name = 'field2', type = 'string', is_nullable = true}
s = box.schema.space.create('test', {engine = 'vinyl', format = format})
_ = s:create_index('pk', {page_size = 16})

pad = string.rep('x', 16)
for i = 101, 200 do s:replace{i, pad} end
box.snapshot()

ch = fiber.channel(1)
test_run:cmd("setopt delimiter ';'")
_ = fiber.create(function()
    fiber.sleep(0.01)
    for i = 1, 100 do
        s:replace{i, box.NULL}
    end
    ch:put(true)
end);
test_run:cmd("setopt delimiter ''");

errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0.001)
format[2].is_nullable = false
s:format(format) -- must fail
errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0)

ch:get()

s:count() -- 200
s:drop()

--
-- gh-2449: change 'unique' index property from true to false
-- is done without index rebuild.
--
s = box.schema.space.create('test', { engine = 'vinyl' })
_ = s:create_index('primary')
_ = s:create_index('secondary', {unique = true, parts = {2, 'unsigned'}})
s:insert{1, 10}
box.snapshot()
errinj.set("ERRINJ_VY_READ_PAGE", true);
s.index.secondary:alter{unique = false} -- ok
s.index.secondary.unique
s.index.secondary:alter{unique = true} -- error
s.index.secondary.unique
errinj.set("ERRINJ_VY_READ_PAGE", false);
s:insert{2, 10}
s.index.secondary:select(10)
s:drop()

--
-- Check that ALTER is aborted if a tuple inserted during index build
-- doesn't conform to the new format.
--
s = box.schema.space.create('test', {engine = 'vinyl'})
_ = s:create_index('pk', {page_size = 16})

pad = string.rep('x', 16)
for i = 101, 200 do s:replace{i, i, pad} end
box.snapshot()

ch = fiber.channel(1)
test_run:cmd("setopt delimiter ';'")
_ = fiber.create(function()
    fiber.sleep(0.01)
    for i = 1, 100 do
        s:replace{i}
    end
    ch:put(true)
end);
test_run:cmd("setopt delimiter ''");

errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0.001)
s:create_index('sk', {parts = {2, 'unsigned'}}) -- must fail
errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0)

ch:get()

s:count() -- 200
s:drop()

--
-- Check that ALTER is aborted if a tuple inserted during index build
-- violates unique constraint.
--
s = box.schema.space.create('test', {engine = 'vinyl'})
_ = s:create_index('pk', {page_size = 16})

pad = string.rep('x', 16)
for i = 101, 200 do s:replace{i, i, pad} end
box.snapshot()

ch = fiber.channel(1)
test_run:cmd("setopt delimiter ';'")
_ = fiber.create(function()
    fiber.sleep(0.01)
    for i = 1, 100 do
        s:replace{i, i + 1}
    end
    ch:put(true)
end);
test_run:cmd("setopt delimiter ''");

errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0.001)
s:create_index('sk', {parts = {2, 'unsigned'}}) -- must fail
errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0)

ch:get()

s:count() -- 200
s:drop()

--
-- Check that modifications done to the space during the final dump
-- of a newly built index are recovered properly.
--
s = box.schema.space.create('test', {engine = 'vinyl'})
_ = s:create_index('pk')

for i = 1, 5 do s:replace{i, i} end

errinj.set("ERRINJ_VY_RUN_WRITE_DELAY", true)
ch = fiber.channel(1)
_ = fiber.create(function() s:create_index('sk', {parts = {2, 'integer'}}) ch:put(true) end)

fiber.sleep(0.01)

_ = s:delete{1}
_ = s:replace{2, -2}
_ = s:delete{2}
_ = s:replace{3, -3}
_ = s:replace{3, -2}
_ = s:replace{3, -1}
_ = s:delete{3}
_ = s:upsert({3, 3}, {{'=', 2, 1}})
_ = s:upsert({3, 3}, {{'=', 2, 2}})
_ = s:delete{3}
_ = s:replace{4, -1}
_ = s:replace{4, -2}
_ = s:replace{4, -4}
_ = s:upsert({5, 1}, {{'=', 2, 1}})
_ = s:upsert({5, 2}, {{'=', 2, -5}})
_ = s:replace{6, -6}
_ = s:upsert({7, -7}, {{'=', 2, -7}})

errinj.set("ERRINJ_VY_RUN_WRITE_DELAY", false)
ch:get()

s.index.sk:select()
s.index.sk:stat().memory.rows

test_run:cmd('restart server default')

fiber = require('fiber')
errinj = box.error.injection

s = box.space.test

s.index.sk:select()
s.index.sk:stat().memory.rows

box.snapshot()

s.index.sk:select()
s.index.sk:stat().memory.rows

s:drop()

--
-- gh-3458: check that rw transactions that started before DDL are
-- aborted.
--
vinyl_cache = box.cfg.vinyl_cache
box.cfg{vinyl_cache = 0}

s1 = box.schema.space.create('test1', {engine = 'vinyl'})
_ = s1:create_index('pk', {page_size = 16})
s2 = box.schema.space.create('test2', {engine = 'vinyl'})
_ = s2:create_index('pk')

pad = string.rep('x', 16)
for i = 101, 200 do s1:replace{i, i, pad} end
box.snapshot()

test_run:cmd("setopt delimiter ';'")
function async_replace(space, tuple, timeout)
    local c = fiber.channel(1)
    fiber.create(function()
        box.begin()
        space:replace(tuple)
        fiber.sleep(timeout)
        local status = pcall(box.commit)
        c:put(status)
    end)
    return c
end;
test_run:cmd("setopt delimiter ''");

c1 = async_replace(s1, {1}, 0.01)
c2 = async_replace(s2, {1}, 0.01)

errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0.001)
s1:format{{'key', 'unsigned'}, {'value', 'unsigned'}}
errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0)

c1:get() -- false (transaction was aborted)
c2:get() -- true

s1:get(1) == nil
s2:get(1) ~= nil
s1:format()
s1:format{}

c1 = async_replace(s1, {2}, 0.01)
c2 = async_replace(s2, {2}, 0.01)

errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0.001)
_ = s1:create_index('sk', {parts = {2, 'unsigned'}})
errinj.set("ERRINJ_VY_READ_PAGE_TIMEOUT", 0)

c1:get() -- false (transaction was aborted)
c2:get() -- true

s1:get(2) == nil
s2:get(2) ~= nil
s1.index.pk:count() == s1.index.sk:count()

s1:drop()
s2:drop()
box.cfg{vinyl_cache = vinyl_cache}

-- Transactions that reached WAL must not be aborted.
s = box.schema.space.create('test', {engine = 'vinyl'})
_ = s:create_index('pk')

errinj.set('ERRINJ_WAL_DELAY', true)
_ = fiber.create(function() s:replace{1} end)
_ = fiber.create(function() fiber.sleep(0.01) errinj.set('ERRINJ_WAL_DELAY', false) end)

fiber.sleep(0)
s:format{{'key', 'unsigned'}, {'value', 'unsigned'}} -- must fail
s:select()
s:truncate()

errinj.set('ERRINJ_WAL_DELAY', true)
_ = fiber.create(function() s:replace{1} end)
_ = fiber.create(function() fiber.sleep(0.01) errinj.set('ERRINJ_WAL_DELAY', false) end)

fiber.sleep(0)
s:create_index('sk', {parts = {2, 'unsigned'}})
s:select()
s:drop()

--
-- gh-4000: index iterator crashes if used throughout DDL.
--
s = box.schema.space.create('test', {engine = 'vinyl'})
_ = s:create_index('pk')
_ = s:create_index('sk', {parts = {2, 'unsigned'}})

s:replace{1, 1}
box.snapshot()

errinj.set('ERRINJ_VY_READ_PAGE_TIMEOUT', 0.01)
c = fiber.channel(1)
_ = fiber.create(function() c:put(s.index.sk:select()) end)
s.index.sk:alter{parts = {2, 'number'}}
errinj.set('ERRINJ_VY_READ_PAGE_TIMEOUT', 0)

c:get()

s:drop()
