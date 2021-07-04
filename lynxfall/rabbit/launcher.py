#cython: language_level=3
"""Lynxfall Task Handling using rabbitmq (simple rabbitmq workers)"""
import asyncio
import importlib
from loguru import logger
from lynxfall.rabbit.core.process import run_worker, disconnect_worker

async def _runner():
    while True:
        try:
            await asyncio.sleep(0)
        except KeyboardInterrupt:
            return
        except:
            logger.exception("Something happened and the worker was forced to shut down!")

def run(**run_worker_args):
    try:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        loop.run_until_complete(run_worker(**run_worker_args))

        # we enter a never-ending loop that waits for data and runs
        # callbacks whenever necessary.
        loop.run_until_complete(_runner())         
    except KeyboardInterrupt:
        try:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            loop.run_until_complete(disconnect_worker())
        except Exception:
            pass
    except Exception:
        logger.exception("Something happened and the worker was forced to shut down!")
