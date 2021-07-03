import aio_pika
import aioredis
from loguru import logger
import nest_asyncio
import builtins
import orjson
from lynxfall.rabbitmq.core.backends import Backends
nest_asyncio.apply()

# Import all needed backends
backends = Backends()
builtins.backends = backends

def serialize(obj):
    try:
        orjson.dumps({"rc": obj})
        return obj
    except:
        try:
            return dict(obj)
        except:
            return str(obj)

async def _new_task(queue):
    friendly_name = backends.getname(queue)
    _channel = await rabbitmq_db.channel()
    _queue = await _channel.declare_queue(instance_name + "." + queue, durable = True) # Function to handle our queue
    async def _task(message: aio_pika.IncomingMessage):
        """RabbitMQ Queue Function"""
        curr = stats.on_message
        logger.opt(ansi = True).info(f"<m>{friendly_name} called (message {curr})</m>")
        stats.on_message += 1
        _json = orjson.loads(message.body)
        _headers = message.headers
        if not _headers:
            logger.error(f"Invalid auth for {friendly_name}")
            message.ack()
            return # No valid auth sent
        if not secure_strcmp(_headers.get("auth"), worker_key):
            logger.error(f"Invalid auth for {friendly_name} and JSON of {_json}")
            message.ack()
            return # No valid auth sent

        # Normally handle rabbitmq task
        _task_handler = TaskHandler(_json, queue)
        rc, err = await _task_handler.handle()
        if isinstance(rc, Exception):
            logger.warning(f"{type(rc).__name__}: {rc} (JSON of {_json})")
            rc = f"{type(rc).__name__}: {rc}"
            stats.err_msgs.append(message) # Mark the failed message so we can ack it later    
        _ret = {"ret": serialize(rc), "err": err}

        if _json["meta"].get("ret"):
            await redis_db.set(f"rabbit.{instance_name}-{_json['meta'].get('ret')}", orjson.dumps(_ret)) # Save return code in redis

        if backends.ackall(queue) or not _ret["err"]: # If no errors recorded
            message.ack()
        logger.opt(ansi = True).info(f"<m>Message {curr} Handled</m>")
        logger.debug(f"Message JSON of {_json}")
        await redis_db.incr(f"{instance_name}.rmq_total_msgs", 1)
        stats.total_msgs += 1
        stats.handled += 1

    await _queue.consume(_task)

class TaskHandler():
    def __init__(self, dict, queue):
        self.dict = dict
        self.ctx = dict["ctx"]
        self.meta = dict["meta"]
        self.queue = queue

    async def handle(self):
        try:
            handler = backends.get(self.queue)
            rc = await handler(self.dict, **self.ctx)
            if isinstance(rc, tuple):
                return rc[0], rc[1]
            elif isinstance(rc, Exception):
                return rc, True
            return rc, False
        except Exception as exc:
            stats.errors += 1 # Record new error
            stats.exc.append(exc)
            return exc, True

class Stats():
    def __init__(self):
        self.errors = 0 # Amount of errors
        self.exc = [] # Exceptions
        self.err_msgs = [] # All messages that failed
        self.on_message = 1 # The currwnt message we are on. Default is 1
        self.handled = 0 # Handled messages count
        self.load_time = None # Amount of time taken to load site
        self.total_msgs = 0 # Total messages

    async def cure(self, index):
        """'Cures a error that has been handled"""
        self.errors -= 1
        await self.err_msgs[index].ack()

    async def cureall(self):
        i = 0
        while i < len(self.err_msgs):
            await self.cure(i)
            i+=1
        self.err_msgs = []
        return "Be sure to reload rabbitmq after this to clear exceptions"

    def __str__(self):
        s = []
        for k in self.__dict__.keys():
            s.append(f"{k}: {self.__dict__[k]}")
        return "\n".join(s)

async def run_worker(*, loop, startup_func, backend_folder, redis_url, rabbit_url, rabbit_args = {}, redis_args = {}):
    """Main worker function"""
    start_time = time.time()
    # Import all needed backends
    backends = Backends(backend_folder = backend_fodler)
    builtins.backends = backends
    logger.opt(ansi = True).info(f"<magenta>Starting Lynxfall RabbitMQ Worker (time: {start_time})...</magenta>")
    builtins.rabbitmq_db = await aio_pika.connect_robust(
        rabbit_url,
        **rabbit_args
    )
    builtins.redis_db = await aioredis.from_url(redis_url, **redis_args) # Redis is required
    state = await startup_func(logger)
    await backends.loadall() # Load all the backends and run prehooks
    builtins.stats = Stats()
    
    # Get handled message count
    stats.total_msgs = await redis_db.get(f"{instance_name}.rmq_total_msgs")
    try:
        stats.total_msgs = int(stats.total_msgs)
    except:
        stats.total_msgs = 0

    await client.wait_until_ready()
    for backend in backends.getall():
        await _new_task(backend)
    end_time = time.time()
    stats.load_time = end_time - start_time
    logger.opt(ansi = True).info(f"<magenta>Worker up in {end_time - start_time} seconds at time {end_time}!</magenta>")

async def disconnect_worker():
    logger.opt(ansi = True).info("<magenta>RabbitMQ worker down. Killing DB connections!</magenta>")
    await rabbitmq_db.disconnect()
    await redis_db.close()
