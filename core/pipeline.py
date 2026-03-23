from datetime import datetime
from core.context import PipelineContext
from core.registry import get_method


class PipelineError(Exception):
    def __init__(self, step: str, method: str, original: Exception):
        self.step = step
        self.method = method
        self.original = original
        super().__init__(
            f"Step '{step}' failed using method '{method}': {original}"
        )


class Pipeline:
    def __init__(self, chain: list[tuple[str, str]], mode: str = "capture"):
        self.chain = chain
        self.mode = mode

    def run(self, ctx: PipelineContext = None) -> PipelineContext:
        if ctx is None:
            ctx = PipelineContext()

        ctx.mode = self.mode
        ctx.timestamp = datetime.now().isoformat()

        print(f"\n{'='*60}")
        print(f"  Pipeline Start | mode={ctx.mode}")
        print(f"  {len(self.chain)} steps to run")
        print(f"{'='*60}\n")

        for step_name, method_name in self.chain:
            print(f"  [{step_name}] → method: {method_name}")

            method_func = get_method(step_name, method_name)

            try:
                ctx = method_func(ctx)
            except Exception as e:
                raise PipelineError(step_name, method_name, e) from e

            output = ctx.get_step_output(step_name)
            if output is None:
                raise PipelineError(
                    step_name,
                    method_name,
                    ValueError(
                        f"Method '{method_name}' did not set step output "
                        f"for '{step_name}'"
                    ),
                )

            print(f"           output: {output.model_dump()}\n")

        print(f"{'='*60}")
        print(f"  Pipeline Complete")
        print(f"{'='*60}\n")

        return ctx